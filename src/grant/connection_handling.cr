module Grant
  # Raised by `Grant::ConnectionHandling.verify!` when a model declares a
  # connection that was never established.
  class UnestablishedConnectionError < Grant::ErrorBase
  end

  # Boot-time checks for the connections models declare with `connects_to`, and
  # the bookkeeping for abstract connection classes. The per-model DSL
  # (`connected_to`, `connecting_to`, ...) lives in `Grant::ConnectionManagement`.
  module ConnectionHandling
    @@declared = {} of String => Proc(Array({String, Symbol, Symbol?}))
    @@primary_abstract_class_name : String? = nil

    # Name of the class marked with `primary_abstract_class`, if any.
    def self.primary_abstract_class_name : String?
      @@primary_abstract_class_name
    end

    # :nodoc:
    def self.primary_abstract_class_name=(name : String)
      @@primary_abstract_class_name = name
    end

    # Records a model's declared connections for `.verify_all!`. Called by
    # `connects_to`; models load once at boot, so no lock is needed.
    #
    # :nodoc:
    def self.declare(model_name : String, names : Proc(Array({String, Symbol, Symbol?})))
      @@declared[model_name] = names
    end

    # Model names that called `connects_to`.
    def self.declared_models : Array(String)
      @@declared.keys
    end

    # Raises `Grant::UnestablishedConnectionError` naming every connection in
    # *names* that the registry does not know, so a typo fails at boot rather
    # than at the first query. A reading connection may be served by the
    # writing or primary connection of the same name, as at query time.
    #
    # ```
    # Grant::ConnectionHandling.verify!("User", User.connection_names)
    # ```
    def self.verify!(model_name : String, names : Array({String, Symbol, Symbol?})) : Nil
      return unless message = missing_connections_message(model_name, names)

      raise Grant::UnestablishedConnectionError.new(
        "#{message}. Establish them with Grant::ConnectionRegistry.establish_connection before verifying.")
    end

    # Verifies every model that called `connects_to` and raises one
    # `Grant::UnestablishedConnectionError` listing every model with missing
    # connections. Call it once after the application has established its
    # connections.
    def self.verify_all! : Nil
      messages = @@declared.compact_map { |model_name, names| missing_connections_message(model_name, names.call) }
      return if messages.empty?

      raise Grant::UnestablishedConnectionError.new(
        "#{messages.join("; ")}. Establish them with Grant::ConnectionRegistry.establish_connection before verifying.")
    end

    private def self.missing_connections_message(model_name : String, names : Array({String, Symbol, Symbol?})) : String?
      missing = names.reject do |(database, role, shard)|
        registry_role = Grant::ConnectionManagement.registry_role(role)
        Grant::ConnectionRegistry.connection_exists?(database, registry_role, shard) ||
          Grant::ConnectionRegistry.connection_exists?(database, :writing, shard) ||
          Grant::ConnectionRegistry.connection_exists?(database, :primary, shard)
      end
      return if missing.empty?

      described = missing.map do |(database, role, shard)|
        shard ? "#{database} (role: #{role}, shard: #{shard})" : "#{database} (role: #{role})"
      end
      "#{model_name} declares connections that are not established: #{described.join(", ")}"
    end
  end

  # The writing role name `connected_to` treats as the writer; `:writing` unless
  # changed on `Grant.settings`.
  def self.writing_role : Symbol
    settings.writing_role
  end

  # The reading role name that implies `prevent_writes`; `:reading` unless
  # changed on `Grant.settings`.
  def self.reading_role : Symbol
    settings.reading_role
  end

  # Runs the block with the given role, shard, and write prevention applied to
  # each listed model class and its subclasses, as ActiveRecord's
  # `connected_to_many`. Accepts the classes as separate arguments or as one
  # array literal, and returns the block's value.
  #
  # ```
  # Grant.connected_to_many(User, Event, role: :reading) do
  #   User.count + Event.count
  # end
  # ```
  macro connected_to_many(*classes, role = nil, shard = nil, prevent_writes = false, &block)
    {% classes = classes[0] if classes.size == 1 && classes[0].is_a?(ArrayLiteral) %}
    {% for klass in classes %}
      {{klass}}.connected_to(role: {{role}}, shard: {{shard}}, prevent_writes: {{prevent_writes}}) do
    {% end %}
    {{block.body}}
    {% for klass in classes %}
      end
    {% end %}
  end
end
