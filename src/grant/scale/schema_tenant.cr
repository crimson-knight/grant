require "./tenant"

module Grant
  # Raised when a schema name is not a safe PostgreSQL identifier.
  class InvalidSchemaNameError < Grant::ErrorBase
  end

  # Raised when schema tenancy is used with a non-PostgreSQL adapter.
  class UnsupportedSchemaTenantAdapterError < Grant::ErrorBase
  end

  # Raised when a model tries to use a different adapter inside one pinned
  # schema-tenant block.
  class SchemaTenantConnectionMismatchError < Grant::ErrorBase
  end

  # Raised when PostgreSQL cannot restore search_path before pool return.
  class SchemaTenantResetError < Grant::ErrorBase
    getter block_exception : ::Exception?

    def initialize(message : String, cause : ::Exception, @block_exception : ::Exception? = nil)
      super(message, cause: cause)
    end
  end

  # PostgreSQL schema-per-tenant context. A block checks out one physical
  # connection (or reuses an already-open transaction connection), sets its
  # search_path, and routes all Grant adapter operations on that fiber through
  # the same connection. Nested switches restore the previous schema, and the
  # outer block resets search_path before pool return.
  class SchemaTenant
    SCHEMA_NAME_PATTERN  = /\A[a-zA-Z_][a-zA-Z0-9_$]*\z/
    MAX_IDENTIFIER_BYTES = 63

    # :nodoc:
    class Context
      getter adapter : Grant::Adapter::Base
      getter connection : DB::Connection
      property schema : String
      property? usable : Bool = true
      property reset_error : SchemaTenantResetError?

      def initialize(@adapter, @connection, @schema)
      end
    end

    @@contexts = {} of Fiber => Context
    @@mutex = Mutex.new

    # Runs *block* with *schema* first in PostgreSQL's search_path and `public`
    # second. All model statements use one pinned connection for the block.
    # Nested calls reuse that connection and restore the outer schema on exit.
    #
    # ```
    # Grant::SchemaTenant.with("acme") do
    #   Invoice.create!(number: "A-1")
    #   Invoice.where(number: "A-1").first
    # end
    # ```
    #
    # Pass `adapter: Model.adapter` when an application has multiple database
    # connections and the default connection is not the tenant database.
    def self.with(schema : String, adapter : Grant::Adapter::Base? = nil, & : -> T) : T forall T
      validate_schema!(schema)
      selected_adapter = postgres_adapter!(adapter || default_adapter)

      if context = current_context
        ensure_same_adapter!(context, selected_adapter)
        previous_schema = context.schema

        begin
          with_reset(
            context.connection,
            search_path_sql(selected_adapter, previous_schema),
            "Could not restore PostgreSQL search_path for schema '#{previous_schema}'",
            context
          ) do
            context.connection.exec(search_path_sql(selected_adapter, schema))
            context.schema = schema
            yield
          end
        ensure
          context.schema = previous_schema
        end
      elsif transaction_connection = Grant::Transaction.current_connection?(selected_adapter)
        with_transaction_connection(schema, selected_adapter, transaction_connection) { yield }
      else
        with_pinned_connection(schema, selected_adapter) { yield }
      end
    end

    # Creates a tenant schema if it does not already exist.
    def self.create_schema(schema : String, adapter : Grant::Adapter::Base? = nil) : Nil
      validate_schema!(schema)
      selected_adapter = postgres_adapter!(adapter || default_adapter)
      selected_adapter.open do |connection|
        connection.exec("CREATE SCHEMA IF NOT EXISTS #{selected_adapter.quote(schema)}")
      end
    end

    # Drops a tenant schema. Set *cascade* when it should also remove its
    # tables, sequences, and other contained objects.
    def self.drop_schema(schema : String, adapter : Grant::Adapter::Base? = nil, cascade : Bool = false) : Nil
      validate_schema!(schema)
      selected_adapter = postgres_adapter!(adapter || default_adapter)
      cascade_sql = cascade ? " CASCADE" : ""
      selected_adapter.open do |connection|
        connection.exec("DROP SCHEMA IF EXISTS #{selected_adapter.quote(schema)}#{cascade_sql}")
      end
      selected_adapter.forget_schema_cache(schema)
    end

    # Lists non-system schemas, excluding `public`, `information_schema`, and
    # PostgreSQL's internal `pg_*` schemas.
    def self.list_schemas(adapter : Grant::Adapter::Base? = nil) : Array(String)
      selected_adapter = postgres_adapter!(adapter || default_adapter)
      schema_names = [] of String

      selected_adapter.open do |connection|
        connection.query(<<-SQL) do |rows|
          SELECT schema_name
          FROM information_schema.schemata
          WHERE schema_name <> 'public'
            AND schema_name <> 'information_schema'
            AND LEFT(schema_name, 3) <> 'pg_'
          ORDER BY schema_name
          SQL
          rows.each { schema_names << rows.read(String) }
        end
      end

      schema_names
    end

    # True when this fiber is inside a schema-tenant block.
    def self.active? : Bool
      !current_context.nil?
    end

    # Returns the schema active on the current fiber, or `nil` outside a block.
    def self.current_schema : String?
      current_context.try(&.schema)
    end

    # The active schema when this fiber's schema-tenant block runs on
    # *adapter*, otherwise `nil`. Unlike `current_connection?` it never raises.
    # :nodoc:
    def self.current_schema_for?(adapter : Grant::Adapter::Base) : String?
      context = current_context
      return unless context && context.adapter.same?(adapter)
      context.schema
    end

    # Returns the current pinned connection for *adapter*. An active schema
    # block rejects statements that resolve to another adapter rather than
    # silently running them without its tenant search_path.
    def self.current_connection?(adapter : Grant::Adapter::Base) : DB::Connection?
      context = current_context
      return unless context

      ensure_same_adapter!(context, adapter)
      context.connection
    end

    # Creates the given model tables inside *schema* using Grant's current
    # per-model migrator. Call this after `create_schema`.
    #
    # ```
    # Grant::SchemaTenant.create_tables("acme", Account, Invoice)
    # ```
    #
    # `schema_tenant_excluded` models target `public`, so create those tables
    # separately once rather than passing them as per-tenant tables.
    macro create_tables(schema, *models)
      {% if models.empty? %}
        {% raise "SchemaTenant.create_tables needs at least one model" %}
      {% end %}

      {% first_model = models.first %}

      Grant::SchemaTenant.with({{schema}}, adapter: {{first_model.id}}.adapter) do
        {% for model in models %}
          {{model.id}}.migrator.create
        {% end %}
      end
    end

    private def self.with_pinned_connection(schema : String, adapter : Grant::Adapter::Base, & : -> T) : T forall T
      adapter.open_pool_connection do |connection|
        context = Context.new(adapter, connection, schema)
        set_current_context(context)

        begin
          with_reset(
            connection,
            "RESET search_path",
            "Could not reset PostgreSQL search_path before returning the tenant connection",
            context,
            close_on_failure: true
          ) do
            connection.exec(search_path_sql(adapter, schema))
            yield
          end
        ensure
          clear_current_context(context)
        end
      end
    end

    private def self.with_transaction_connection(schema : String, adapter : Grant::Adapter::Base, connection : DB::Connection, & : -> T) : T forall T
      context = Context.new(adapter, connection, schema)
      set_current_context(context)

      begin
        with_reset(
          connection,
          "RESET search_path",
          "Could not reset PostgreSQL search_path before leaving the tenant block",
          context,
          close_on_failure: true
        ) do
          connection.exec(search_path_sql(adapter, schema))
          yield
        end
      ensure
        clear_current_context(context)
      end
    end

    private def self.with_reset(
      connection : DB::Connection,
      reset_sql : String,
      message : String,
      context : Context? = nil,
      close_on_failure : Bool = false,
      & : -> T
    ) : T forall T
      block_exception = nil.as(::Exception?)

      begin
        yield
      rescue ex : ::Exception
        block_exception = ex
        raise ex
      ensure
        begin
          connection.exec(reset_sql)
        rescue reset_exception : DB::Error | IO::Error
          context.try(&.usable=(false))

          if close_on_failure
            begin
              connection.close
            rescue close_exception : DB::Error | IO::Error
              Grant::Log.warn(exception: close_exception) do
                "Could not close PostgreSQL connection after search_path reset failed"
              end
            end
          end

          reset_error = SchemaTenantResetError.new(
            "#{message}: #{reset_exception.message}",
            cause: reset_exception,
            block_exception: block_exception
          )
          context.try(&.reset_error=(reset_error))
          if original_exception = block_exception
            if grant_exception = original_exception.as?(Grant::ErrorBase)
              grant_exception.cleanup_error = reset_error
            end
            Grant::Log.warn(exception: reset_error) do
              "Preserving schema-tenant block exception #{original_exception.class} after search_path reset failed"
            end
            raise original_exception
          else
            raise reset_error
          end
        end
      end
    end

    private def self.search_path_sql(adapter : Grant::Adapter::Base, schema : String) : String
      "SET search_path TO #{adapter.quote(schema)}, public"
    end

    private def self.validate_schema!(schema : String) : Nil
      unless schema.bytesize <= MAX_IDENTIFIER_BYTES && schema.matches?(SCHEMA_NAME_PATTERN)
        raise InvalidSchemaNameError.new(
          "Invalid PostgreSQL schema name #{schema.inspect}; use 1-63 ASCII letters, digits, underscores, or dollar signs, starting with a letter or underscore"
        )
      end

      if schema == "public" || schema.downcase.starts_with?("pg_")
        raise InvalidSchemaNameError.new("PostgreSQL schema name #{schema.inspect} is reserved for schema tenancy")
      end
    end

    private def self.postgres_adapter!(adapter : Grant::Adapter::Base) : Grant::Adapter::Base
      unless adapter.postgres?
        raise UnsupportedSchemaTenantAdapterError.new(
          "Grant schema tenancy requires PostgreSQL; got #{adapter.class.name}"
        )
      end
      adapter
    end

    private def self.default_adapter : Grant::Adapter::Base
      database = Grant::ConnectionRegistry.default_database
      Grant::ConnectionRegistry.get_adapter(database, :writing)
    end

    private def self.current_context : Context?
      @@mutex.synchronize { @@contexts[Fiber.current]? }
    end

    private def self.set_current_context(context : Context) : Nil
      @@mutex.synchronize { @@contexts[Fiber.current] = context }
    end

    private def self.clear_current_context(context : Context) : Nil
      @@mutex.synchronize do
        fiber = Fiber.current
        if @@contexts[fiber]?.try(&.same?(context))
          @@contexts.delete(fiber)
        end
      end
    end

    private def self.ensure_same_adapter!(context : Context, adapter : Grant::Adapter::Base) : Nil
      unless context.usable?
        raise SchemaTenantResetError.new(
          "The schema-tenant connection could not restore schema '#{context.schema}' and is no longer usable",
          cause: context.reset_error || Grant::ErrorBase.new("The previous schema reset failed")
        )
      end

      return if context.adapter.same?(adapter)

      raise SchemaTenantConnectionMismatchError.new(
        "Schema tenant '#{context.schema}' pins connection '#{context.adapter.name}'; " \
        "model connection '#{adapter.name}' cannot run inside the same schema-tenant block"
      )
    end
  end

  # Per-model declaration for models whose tables always live in `public`.
  abstract class Grant::Base
    def self.schema_tenant_excluded? : Bool
      false
    end

    macro schema_tenant_excluded
      {% table_annotation = @type.annotation(Grant::Table) %}
      {% model_table_name = if table_annotation && table_annotation[:name]
                              table_annotation[:name]
                            else
                              @type.name.underscore.stringify.split("::").last
                            end %}

      def self.schema_tenant_excluded? : Bool
        true
      end

      def self.table_name : String
        "public.#{ {{model_table_name}} }"
      end
    end
  end
end
