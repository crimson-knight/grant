# Model-level connection API: establishing, inspecting, pinning and removing
# the connections a model reads and writes through. Mixed into every
# `Grant::Base` model next to `Grant::ConnectionManagement`.
module Grant::ConnectionManagement
  module PoolClassMethods
    # Establishes a connection under this model's database name (or *database*)
    # and returns nothing. It is `Grant::ConnectionRegistry.establish_connection`
    # for the model's own database; *role* defaults to the writing role and
    # accepts the configured role names. Re-establishing a connection closes
    # the pool it replaces. Pool options (`pool_size`, `checkout_timeout`,
    # `max_idle_pool_size`, `prepared_statements`, ...) pass through.
    #
    # ```
    # User.establish_connection(url: "postgres://localhost/app", adapter: Grant::Adapter::Pg, pool_size: 10)
    # ```
    def establish_connection(url : String, adapter : Grant::Adapter::Base.class,
                             role : Symbol = Grant.settings.writing_role,
                             database : String = default_database_name,
                             shard : Symbol? = nil, **pool_options) : Nil
      Grant::ConnectionRegistry.establish_connection(
        **pool_options, database: database, adapter: adapter, url: url,
        role: Grant::ConnectionManagement.registry_role(role), shard: shard
      )
    end

    # Closes and removes this model's connection for *role* (the writing role
    # by default). Returns `false` when it was not established.
    def remove_connection(role : Symbol = Grant.settings.writing_role, shard : Symbol? = current_shard) : Bool
      name = connection_config[Grant::ConnectionManagement.canonical_role(role)]? || current_database
      Grant::ConnectionRegistry.remove_connection(name, Grant::ConnectionManagement.registry_role(role), shard)
    end

    # True when this model's writer is established and answers `SELECT 1`.
    def connected? : Bool
      pool = retrieve_connection_pool
      !pool.nil? && pool.active?
    end

    # The `Grant::ConnectionPool` behind this model's connection for *role*, or
    # `nil` when that connection was never established. Unlike `adapter`, it
    # never falls back to another role.
    def retrieve_connection_pool(role : Symbol = Grant.settings.writing_role, shard : Symbol? = current_shard) : Grant::ConnectionPool?
      name = connection_config[Grant::ConnectionManagement.canonical_role(role)]? || current_database
      Grant::ConnectionRegistry.connection_pool(name, Grant::ConnectionManagement.registry_role(role), shard)
    end

    # The `Grant::ConnectionPool` behind this model's connection for *role*.
    # Raises `Grant::AdapterNotAvailableError` when none is established.
    #
    # ```
    # User.connection_pool.stat # => Grant::PoolStat(size: 25, connections: 2, busy: 0, idle: 2, ...)
    # ```
    def connection_pool(role : Symbol = Grant.settings.writing_role) : Grant::ConnectionPool
      Grant::ConnectionPool.new(connection_adapter(role))
    end

    # Closes every pool this model's database uses (all roles and replicas).
    # Each reopens on next use.
    def disconnect! : Nil
      Grant::ConnectionRegistry.adapters_for_database(current_database).each(&.disconnect!)
    end

    # Yields one raw `DB::Connection` and routes every Grant operation of this
    # fiber on this model's writer through it until the block ends, for session
    # state such as `SET LOCAL`, temp tables, advisory locks or `LISTEN`. A
    # transaction opened inside the block uses the same connection.
    #
    # The block holds a pooled connection for its whole run: keep slow
    # non-database work out of it.
    #
    # ```
    # User.with_connection do |raw|
    #   raw.exec("CREATE TEMP TABLE scratch (id INTEGER)")
    #   User.count # runs on the same connection
    # end
    # ```
    def with_connection(& : DB::Connection -> T) : T forall T
      explicit_role = connection_context.try(&.role)
      if preventing_writes? || explicit_role
        adapter.with_connection { |raw| yield raw }
      else
        connected_to(role: Grant.settings.writing_role) do
          adapter.with_connection { |raw| yield raw }
        end
      end
    end
  end
end
