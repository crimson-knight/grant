module Grant
  # Raw, bound SQL access to a selected Grant database connection.
  #
  # `execute` uses the write role. Read helpers use the model's active read
  # routing or the named connection's reading role. Every operation goes
  # through `Grant::Adapter::Base#open`, so an active transaction or schema
  # tenant keeps using its pinned database connection. Connection calls are
  # explicitly raw and do not apply model default scopes. `execute` still
  # respects an active write-prevention context.
  #
  # ```
  # Grant.connection.select_value("SELECT name FROM users WHERE id = ?", [1_i64])
  # Grant.connection.execute("DELETE FROM sessions WHERE expires_at < ?", [Time.utc])
  # ```
  class Connection
    alias AdapterResolver = Proc(Symbol, Grant::Adapter::Base)
    alias BeforeWrite = Proc(Nil)

    @before_write : BeforeWrite

    def initialize(
      @adapter_resolver : AdapterResolver,
      @before_write : BeforeWrite = -> { nil },
    )
    end

    # Returns the adapter selected for *role*. Primarily useful for diagnostics
    # and adapter-aware sanitization.
    def adapter(role : Symbol = Grant.settings.reading_role) : Grant::Adapter::Base
      @adapter_resolver.call(role)
    end

    # Yields one raw `DB::Connection` from the write role's pool and keeps every
    # Grant statement of this fiber on that adapter on it until the block ends,
    # for session state such as `SET LOCAL`, temp tables, advisory locks or
    # `LISTEN`. Inside a transaction the transaction's connection is yielded.
    # Hold it only for database work: it takes a connection out of the pool for
    # the whole block.
    #
    # ```
    # Grant.connection.with_connection do |raw|
    #   raw.exec("CREATE TEMP TABLE scratch (id INTEGER)")
    #   Grant.connection.execute("INSERT INTO scratch VALUES (1)")
    # end
    # ```
    def with_connection(role : Symbol = Grant.settings.writing_role, & : DB::Connection -> T) : T forall T
      adapter(role).with_connection { |raw| yield raw }
    end

    # Executes a bound statement on the selected write connection.
    def execute(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : DB::ExecResult
      Grant::ConnectionManagement.guard_writes!
      @before_write.call
      selected_adapter = adapter(Grant.settings.writing_role)
      statement = Grant::QueryLogs.append(selected_adapter.ensure_clause_template(sql))
      Grant::Logs.timed(selected_adapter, statement, binds) do
        selected_adapter.open(statement, binds) do |database|
          database.exec(statement, args: selected_adapter.normalize_bind_values(binds))
        end
      end
    end

    # Runs a bound query on the selected read connection and buffers its rows.
    def exec_query(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result
      selected_adapter = adapter(Grant.settings.reading_role)
      statement = Grant::QueryLogs.append(selected_adapter.ensure_clause_template(sql))
      Grant::Logs.timed(selected_adapter, statement, binds) do
        selected_adapter.open(statement, binds) do |database|
          database.query(statement, args: selected_adapter.normalize_bind_values(binds)) do |result_set|
            return Grant::Result.from(result_set, selected_adapter)
          end
        end
      end
      raise DB::Error.new("The selected adapter did not yield a result set")
    end

    # Rails-compatible alias for `#exec_query`.
    def select_all(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result
      exec_query(sql, binds)
    end

    # Returns the first result row as a hash, or `nil` when the query has no rows.
    def select_one(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result::HashRow?
      exec_query(sql, binds).to_a.first?
    end

    # Returns the first column of the first result row, or `nil` when absent.
    def select_value(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Grant::Result::Value?
      result = exec_query(sql, binds)
      return if result.rows.empty?
      result.rows.first.first?
    end

    # Returns the first column from every result row.
    def select_values(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Array(Grant::Result::Value)
      result = exec_query(sql, binds)
      result.rows.map(&.first)
    end

    # Returns every result row as positional values.
    def select_rows(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type) : Array(Grant::Result::Row)
      exec_query(sql, binds).rows
    end

    # Yields the live result set for model hydration without first coercing
    # database values into buffered rows.
    def with_result_set(sql : String, binds : Array(Grant::Columns::Type) = [] of Grant::Columns::Type, & : DB::ResultSet -> T) : T forall T
      selected_adapter = adapter(Grant.settings.reading_role)
      statement = Grant::QueryLogs.append(selected_adapter.ensure_clause_template(sql))
      Grant::Logs.timed(selected_adapter, statement, binds) do
        selected_adapter.open(statement, binds) do |database|
          database.query(statement, args: selected_adapter.normalize_bind_values(binds)) do |result_set|
            return yield result_set
          end
        end
      end
      raise DB::Error.new("The selected adapter did not yield a result set")
    end
  end

  # Returns a raw connection facade for a named connection. Read operations use
  # its `:reading` role with the registry's normal fallback; writes use its
  # `:writing` role. The default database is used when *name* is omitted.
  def self.connection(name : String? = nil) : Grant::Connection
    database_name = name || ConnectionRegistry.default_database
    Connection.new(->(role : Symbol) { ConnectionRegistry.get_adapter(database_name, ConnectionManagement.registry_role(role)) })
  end
end
