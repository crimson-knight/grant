require "./health_monitor"
require "./replica_load_balancer"
require "./pool_reaper"
require "./connection_pool"
require "../adapter/registry"

module Grant
  # Raised when a model resolves an adapter for a connection that was never
  # established — for example because the active build target did not register
  # that connection, or because the matching adapter shard was not compiled in
  # (no `require "grant/adapter/<name>"` for this build entrypoint).
  #
  # The message names the connection, the active build target, and the adapters
  # that *were* compiled in (`Grant.compiled_adapters`) so the fix is obvious:
  # either establish the connection for this target, or `require` the missing
  # adapter.
  class AdapterNotAvailableError < ConnectionNotEstablished
  end

  # Central registry for managing database connections
  class ConnectionRegistry
    # Connection specification with pool configuration
    struct ConnectionSpec
      property database : String
      property adapter_class : Grant::Adapter::Base.class
      property role : Symbol
      property shard : Symbol?

      # The connection URL. When the connection was registered with an eager
      # `url : String`, this is set immediately. When registered with a lazy
      # `url_provider : -> String`, this stays nil until the provider is invoked
      # (once) on first pool build — see `#resolved_url`.
      @url : String?

      # Lazy URL provider. Invoked at most once, on first pool build, then its
      # result is memoized into `@url`. Device targets that compute their DB
      # path at runtime (e.g. an app-support directory only known after boot)
      # register with this instead of an eager URL.
      @url_provider : (-> String)?

      # Pool configuration
      property pool_size : Int32 = 25
      property initial_pool_size : Int32 = 2
      property checkout_timeout : Time::Span = 5.seconds
      property retry_attempts : Int32 = 1
      property retry_delay : Time::Span = 0.2.seconds

      # Most idle connections the pool keeps. `nil` means "as many as the pool
      # holds" for server adapters (so a burst does not open and close
      # connections) and the driver default for SQLite.
      property max_idle_pool_size : Int32? = nil

      # Reaper configuration. With none of `idle_timeout`, `keepalive` and
      # `max_age` set no reaper runs. `idle_timeout` closes idle connections
      # (keeping `min_connections`) once nothing was checked out for that long;
      # `keepalive` pings idle connections at that interval; `max_age` retires
      # connections open longer than that; the reaper wakes every
      # `reaping_frequency`.
      property idle_timeout : Time::Span? = nil
      property keepalive : Time::Span? = nil
      property max_age : Time::Span? = nil
      property reaping_frequency : Time::Span = 1.minute
      property min_connections : Int32 = 0

      # How long a connection may sit idle before it is probed with `SELECT 1`
      # as it is checked out, and replaced if the probe fails. `nil` turns the
      # probe off. See `Grant::Adapter::Base#verify_idle_after`.
      property verify_idle_after : Time::Span? = 30.seconds

      # Prepared statements. `prepared_statements: false` is for PgBouncer in
      # transaction mode (SQLite always prepares). `statement_limit` bounds
      # the prepared statements cached per connection; 0 turns the cache off.
      property prepared_statements : Bool = true
      property statement_limit : Int32 = 1000

      # Which read replica of a database/shard this connection is, and how many
      # reads a weighted strategy sends it. Only used by the `:reading` role.
      property replica_index : Int32 = 0
      property replica_weight : Int32 = 1

      # Health check configuration
      property health_check_interval : Time::Span = 30.seconds
      property health_check_timeout : Time::Span = 5.seconds

      def initialize(@database, @adapter_class, url : String, @role, @shard = nil,
                     @pool_size = 25, @initial_pool_size = 2,
                     @checkout_timeout = 5.seconds, @retry_attempts = 1,
                     @retry_delay = 0.2.seconds, @health_check_interval = 30.seconds,
                     @health_check_timeout = 5.seconds, *,
                     @max_idle_pool_size = nil, @idle_timeout = nil, @keepalive = nil,
                     @reaping_frequency = 1.minute, @min_connections = 0, @max_age = nil,
                     @prepared_statements = true, @statement_limit = 1000,
                     @replica_index = 0, @replica_weight = 1, @verify_idle_after = 30.seconds)
        @url = url
        @url_provider = nil
      end

      # Lazy-URL constructor. The provider is *not* invoked here; it is resolved
      # on first pool build via `#resolved_url`.
      def initialize(@database, @adapter_class, @role, *, url_provider : -> String, @shard = nil,
                     @pool_size = 25, @initial_pool_size = 2,
                     @checkout_timeout = 5.seconds, @retry_attempts = 1,
                     @retry_delay = 0.2.seconds, @health_check_interval = 30.seconds,
                     @health_check_timeout = 5.seconds,
                     @max_idle_pool_size = nil, @idle_timeout = nil, @keepalive = nil,
                     @reaping_frequency = 1.minute, @min_connections = 0, @max_age = nil,
                     @prepared_statements = true, @statement_limit = 1000,
                     @replica_index = 0, @replica_weight = 1, @verify_idle_after = 30.seconds)
        @url = nil
        @url_provider = url_provider
      end

      # True when this spec was registered with a lazy `url_provider` and has not
      # resolved it yet.
      def lazy? : Bool
        @url.nil? && !@url_provider.nil?
      end

      # Resolves the connection URL, invoking (and memoizing) the lazy provider
      # on first call. Subsequent calls return the cached URL — the provider
      # runs at most once.
      def resolved_url : String
        if existing = @url
          return existing
        end
        if provider = @url_provider
          resolved = provider.call
          @url = resolved
          return resolved
        end
        raise Grant::AdapterNotAvailableError.new(
          "Connection '#{@database}' (role #{@role}) has neither a URL nor a URL provider"
        )
      end

      # Backwards-compatible accessor. For eager specs this returns the URL
      # given at registration; for lazy specs it resolves the provider (so any
      # existing caller that read `.url` keeps working, triggering lazy
      # resolution at the point of first use rather than at registration).
      def url : String
        resolved_url
      end

      # Returns the registry key (`String`) identifying this connection:
      # `"<database>:<role>"`, or `"<database>:<role>:<shard>"` when sharded.
      # The second and later read replicas of a database add `#<index>` to the
      # role (`"primary:reading#1"`).
      def connection_key : String
        ConnectionRegistry.key_for(database, role, shard, replica_index)
      end

      # Returns the connection URL (`String`) with the pool settings appended
      # as crystal-db query parameters (`max_pool_size`, `initial_pool_size`,
      # `max_idle_pool_size`, `checkout_timeout`, `retry_attempts`,
      # `retry_delay`, and `prepared_statements` /
      # `prepared_statements_cache` when they differ from the defaults).
      # Resolves a lazy `url_provider` if needed.
      #
      # A database that lives inside one connection (SQLite `:memory:`) is
      # always given a pool of exactly one connection, since a second one would
      # be a different, empty database.
      def build_pool_url : String
        source_url = resolved_url
        uri = URI.parse(source_url)
        params = uri.query_params

        if adapter_class.single_connection_url?(source_url)
          params["max_pool_size"] = "1"
          params["initial_pool_size"] = "1"
          params["max_idle_pool_size"] = "1"
        else
          params["max_pool_size"] = @pool_size.to_s
          params["initial_pool_size"] = Math.min(@initial_pool_size, @pool_size).to_s
          idle_limit = @max_idle_pool_size || (adapter_class.server_adapter? ? @pool_size : nil)
          params["max_idle_pool_size"] = idle_limit.to_s if idle_limit
        end
        params["checkout_timeout"] = @checkout_timeout.total_seconds.to_s
        params["retry_attempts"] = @retry_attempts.to_s
        params["retry_delay"] = @retry_delay.total_seconds.to_s

        params["prepared_statements"] = "false" if !@prepared_statements && adapter_class.supports_unprepared_statements?
        params["prepared_statements_cache"] = "false" if @statement_limit == 0

        uri.query = params.to_s
        uri.to_s
      end
    end

    # Class-level storage. The three hashes are immutable snapshots: writers
    # (which hold `@@mutex`) build a new hash and swap the reference, so lookups
    # on the query path, pool statistics and replica choice read them without a
    # lock. Pools are always closed after the mutex is released.
    @@adapters = {} of String => Grant::Adapter::Base
    @@specifications = {} of String => ConnectionSpec
    @@load_balancers = {} of String => ReplicaLoadBalancer
    @@reapers = {} of String => PoolReaper
    @@database_options = {} of String => DatabaseOptions
    @@mutex = Mutex.new
    @@default_database : String? = nil

    # Settings applied to every connection of one database, declared on a model
    # before or after its connections exist.
    private record DatabaseOptions,
      retry_attempts : Int32? = nil,
      health_check_interval : Time::Span? = nil,
      load_balancing_strategy : LoadBalancingStrategy? = nil

    # Returns the registry key for a connection: `"<database>:<role>"`, with
    # `#<replica_index>` after the role for the second and later replicas and
    # `:<shard>` at the end when sharded.
    def self.key_for(database : String, role : Symbol, shard : Symbol? = nil, replica_index : Int32 = 0) : String
      lookup = {database, role, shard, replica_index}
      if key = @@key_cache[lookup]?
        return key
      end

      key = if replica_index > 0
              shard ? "#{database}:#{role}##{replica_index}:#{shard}" : "#{database}:#{role}##{replica_index}"
            else
              shard ? "#{database}:#{role}:#{shard}" : "#{database}:#{role}"
            end
      remember_key(lookup, key)
      key
    end

    # Every model resolves its adapter through `key_for`, so the key text of a
    # connection is built once. The map is replaced, never written in place,
    # so readers need no lock; it stops growing at KEY_CACHE_LIMIT entries.
    KEY_CACHE_LIMIT = 4096
    @@key_cache = {} of Tuple(String, Symbol, Symbol?, Int32) => String
    @@key_cache_mutex = Mutex.new

    private def self.remember_key(lookup : Tuple(String, Symbol, Symbol?, Int32), key : String) : Nil
      @@key_cache_mutex.synchronize do
        return if @@key_cache.size >= KEY_CACHE_LIMIT
        cache = @@key_cache.dup
        cache[lookup] = key
        @@key_cache = cache
      end
    end

    private def self.balancer_key(database : String, shard : Symbol?) : String
      shard ? "#{database}:#{shard}" : database
    end

    # Registers a database connection from an **eager** URL string and builds its
    # adapter (and pool) immediately. This is the form most apps use.
    #
    # * *database* — the connection name models refer to (via `connection` /
    #   `connects_to`). The first connection registered becomes the default.
    # * *adapter* — the adapter class, e.g. `Grant::Adapter::Sqlite`,
    #   `Grant::Adapter::Pg`, `Grant::Adapter::Mysql` (must be `require`d).
    # * *url* — the connection URL.
    # * *role* — `:primary` (default), `:writing`, or `:reading`. Register a
    #   `:reading` connection alongside a writer to enable read/write splitting.
    #   Registering the same database, role, shard and *replica_index* again
    #   replaces that connection and closes its old pool.
    # * *shard* — name this connection's shard for horizontal sharding, or leave
    #   `nil`.
    # * *replica_index* / *replica_weight* — register several `:reading`
    #   replicas of one database (index 0, 1, 2, ...) and, for `WeightedStrategy`,
    #   how many reads each gets.
    # * *pool_size*, *initial_pool_size*, *checkout_timeout*, *retry_attempts*,
    #   *retry_delay* — the connection pool. *max_idle_pool_size* defaults to
    #   *pool_size* for server databases so bursts reuse connections.
    #   *retry_attempts* and *retry_delay* govern retrying a refused connection
    #   and a lost read, with capped exponential backoff; a lost write is never
    #   retried.
    # * *idle_timeout*, *keepalive*, *max_age*, *reaping_frequency*,
    #   *min_connections* — opt-in idle reaping (see `PoolReaper`).
    # * *prepared_statements*, *statement_limit* — prepared statement behavior.
    # * *verify_idle_after* — a connection idle this long (30 seconds by default;
    #   `nil` disables) is probed with `SELECT 1` when taken from the pool and
    #   replaced when it is dead, so a restarted server does not fail one
    #   statement per idle connection. Busier connections are never probed.
    # * *health_check_interval* / *health_check_timeout* — the health monitor.
    #
    # For a URL that is only known at runtime (a device's data directory, say),
    # use the `url_provider:` overload instead.
    #
    # ```
    # Grant::ConnectionRegistry.establish_connection(
    #   database: "primary",
    #   adapter: Grant::Adapter::Sqlite,
    #   url: "sqlite3:./app.db"
    # )
    # ```
    def self.establish_connection(
      database : String,
      adapter : Grant::Adapter::Base.class,
      url : String,
      role : Symbol = :primary,
      shard : Symbol? = nil,
      pool_size : Int32 = 25,
      initial_pool_size : Int32 = 2,
      checkout_timeout : Time::Span = 5.seconds,
      retry_attempts : Int32 = 1,
      retry_delay : Time::Span = 0.2.seconds,
      health_check_interval : Time::Span = 30.seconds,
      health_check_timeout : Time::Span = 5.seconds,
      max_idle_pool_size : Int32? = nil,
      idle_timeout : Time::Span? = nil,
      keepalive : Time::Span? = nil,
      max_age : Time::Span? = nil,
      reaping_frequency : Time::Span = 1.minute,
      min_connections : Int32 = 0,
      prepared_statements : Bool = true,
      statement_limit : Int32 = 1000,
      replica_index : Int32 = 0,
      replica_weight : Int32 = 1,
      verify_idle_after : Time::Span? = 30.seconds,
    )
      spec = ConnectionSpec.new(
        database, adapter, url, role, shard,
        pool_size, initial_pool_size, checkout_timeout,
        retry_attempts, retry_delay, health_check_interval,
        health_check_timeout,
        max_idle_pool_size: max_idle_pool_size, idle_timeout: idle_timeout,
        keepalive: keepalive, max_age: max_age, reaping_frequency: reaping_frequency,
        min_connections: min_connections, prepared_statements: prepared_statements,
        statement_limit: statement_limit, replica_index: replica_index,
        replica_weight: replica_weight, verify_idle_after: verify_idle_after
      )
      register_spec(spec, eager: true)
    end

    # Establishes a connection whose adapter is chosen from the *url* scheme
    # (`postgres://`, `mysql://`, `sqlite3:`) using `Grant::Adapter::Registry`.
    # Only adapters that were required are known; an unknown scheme raises
    # `Grant::UnknownAdapterError`. Accepts every option of the explicit-adapter
    # overload.
    #
    # ```
    # Grant::ConnectionRegistry.establish_connection(
    #   database: "primary", url: "postgres://localhost/app")
    # ```
    def self.establish_connection(database : String, url : String, role : Symbol = :primary, shard : Symbol? = nil, **options)
      adapter = Grant::Adapter::Registry.for_url(url)
      establish_connection(**options, database: database, adapter: adapter, url: url, role: role, shard: shard)
    end

    # Establish a new connection with a *lazy* URL provider.
    #
    # The provider proc is **not** invoked at registration — it runs once, on
    # first pool build (i.e. when a query first checks out this connection). This
    # is the form device/desktop targets use when the database path is only known
    # after the app has booted (e.g. an OS-provided app-support directory).
    #
    # ```
    # Grant::ConnectionRegistry.establish_connection(
    #   database: "primary",
    #   adapter: Grant::Adapter::Sqlite,
    #   url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" })
    # ```
    def self.establish_connection(
      database : String,
      adapter : Grant::Adapter::Base.class,
      url_provider : -> String,
      role : Symbol = :primary,
      shard : Symbol? = nil,
      pool_size : Int32 = 25,
      initial_pool_size : Int32 = 2,
      checkout_timeout : Time::Span = 5.seconds,
      retry_attempts : Int32 = 1,
      retry_delay : Time::Span = 0.2.seconds,
      health_check_interval : Time::Span = 30.seconds,
      health_check_timeout : Time::Span = 5.seconds,
      max_idle_pool_size : Int32? = nil,
      idle_timeout : Time::Span? = nil,
      keepalive : Time::Span? = nil,
      max_age : Time::Span? = nil,
      reaping_frequency : Time::Span = 1.minute,
      min_connections : Int32 = 0,
      prepared_statements : Bool = true,
      statement_limit : Int32 = 1000,
      replica_index : Int32 = 0,
      replica_weight : Int32 = 1,
      verify_idle_after : Time::Span? = 30.seconds,
    )
      spec = ConnectionSpec.new(
        database, adapter, role, url_provider: url_provider, shard: shard,
        pool_size: pool_size, initial_pool_size: initial_pool_size,
        checkout_timeout: checkout_timeout, retry_attempts: retry_attempts,
        retry_delay: retry_delay, health_check_interval: health_check_interval,
        health_check_timeout: health_check_timeout,
        max_idle_pool_size: max_idle_pool_size, idle_timeout: idle_timeout,
        keepalive: keepalive, max_age: max_age, reaping_frequency: reaping_frequency,
        min_connections: min_connections, prepared_statements: prepared_statements,
        statement_limit: statement_limit, replica_index: replica_index,
        replica_weight: replica_weight, verify_idle_after: verify_idle_after
      )
      # eager: false → the adapter instance (and therefore the URL provider) is
      # not materialized until first use.
      register_spec(spec, eager: false)
    end

    # Registers several read replicas of *database* in one call, one per URL in
    # *urls* (replica index 0, 1, 2, ...). Reads spread across them by the
    # database's load balancing strategy. The remaining keyword arguments are
    # those of `#establish_connection`, applied to every replica.
    #
    # ```
    # Grant::ConnectionRegistry.establish_replicas(
    #   database: "primary",
    #   adapter: Grant::Adapter::Pg,
    #   urls: ["postgres://replica-a/app", "postgres://replica-b/app"]
    # )
    # ```
    def self.establish_replicas(database : String, adapter : Grant::Adapter::Base.class, urls : Array(String), shard : Symbol? = nil, **options) : Nil
      urls.each_with_index do |url, index|
        establish_connection(
          **options, database: database, adapter: adapter, url: url, role: :reading,
          shard: shard, replica_index: index
        )
      end
    end

    # Stores a spec and, when *eager* is true (or the spec carries an eager URL),
    # immediately materializes the adapter instance. Lazy specs defer adapter
    # creation — and thus URL-provider invocation — to the first `get_adapter`.
    # Registering over an existing key closes the adapter it replaces, after
    # the registry lock is released.
    private def self.register_spec(spec : ConnectionSpec, eager : Bool)
      key = spec.connection_key
      retired = [] of Grant::Adapter::Base

      @@mutex.synchronize do
        spec = with_database_options(spec)

        # A replaced connection that was never materialized has no pool; one
        # that was must be closed.
        if previous = @@adapters[key]?
          retired << previous
        end

        specifications = @@specifications.dup
        specifications[key] = spec
        @@specifications = specifications

        # Set as default if first database
        @@default_database ||= spec.database

        # Materialize eagerly only for eager specs. Lazy specs are built on the
        # first checkout via #ensure_materialized (called from get_adapter).
        if eager && !spec.lazy?
          materialize_adapter(spec)
        elsif previous
          adapters = @@adapters.dup
          adapters.delete(key)
          @@adapters = adapters
          unlink_replica(spec, key)
        end
      end

      retire(retired)
    end

    # Closes retired adapters. Callers invoke this with the registry lock
    # released, because closing a pool is network I/O.
    private def self.retire(retired : Array(Grant::Adapter::Base)) : Nil
      retired.each(&.disconnect!)
    end

    # Applies settings declared with `#configure_database` to *spec*.
    private def self.with_database_options(spec : ConnectionSpec) : ConnectionSpec
      return spec unless options = @@database_options[spec.database]?

      if attempts = options.retry_attempts
        spec.retry_attempts = attempts
      end
      if interval = options.health_check_interval
        spec.health_check_interval = interval
      end
      spec
    end

    # Builds the concrete adapter instance for *spec* (resolving its URL,
    # invoking a lazy provider exactly once) and registers it, its health
    # monitor, its reaper, and — for reading roles — its load-balancer entry.
    # Must be called while holding `@@mutex`.
    private def self.materialize_adapter(spec : ConnectionSpec) : Grant::Adapter::Base
      key = spec.connection_key

      # Create adapter instance with pooled URL (this resolves a lazy provider).
      adapter_instance = spec.adapter_class.new(key, spec.build_pool_url)
      adapter_instance.retry_attempts = spec.retry_attempts
      adapter_instance.retry_delay = spec.retry_delay
      adapter_instance.statement_limit = spec.statement_limit
      adapter_instance.idle_timeout = spec.idle_timeout
      adapter_instance.min_connections = spec.min_connections
      adapter_instance.keepalive = spec.keepalive
      adapter_instance.max_age = spec.max_age
      adapter_instance.verify_idle_after = spec.verify_idle_after

      adapters = @@adapters.dup
      adapters[key] = adapter_instance
      @@adapters = adapters

      # Register the health monitor. It only starts its background timer
      # outside test mode, but on-demand checks (`verify!`) work either way.
      HealthMonitorRegistry.register(key, adapter_instance, spec)

      start_reaper(key, adapter_instance, spec)

      # Track read replicas for load balancing
      if spec.role == :reading
        link_replica(spec, key, adapter_instance)
      end

      adapter_instance
    end

    private def self.start_reaper(key : String, adapter : Grant::Adapter::Base, spec : ConnectionSpec) : Nil
      reapers = @@reapers.dup
      reapers.delete(key).try(&.stop)
      if (spec.idle_timeout || spec.keepalive || spec.max_age) && !HealthMonitor.test_mode
        reaper = PoolReaper.new(adapter, spec.reaping_frequency)
        reaper.start
        reapers[key] = reaper
      end
      @@reapers = reapers
    end

    # Adds a materialized reading connection to its database's balancer,
    # replacing the entry a previous registration under the same key left.
    private def self.link_replica(spec : ConnectionSpec, key : String, adapter : Grant::Adapter::Base) : Nil
      lb_key = balancer_key(spec.database, spec.shard)
      balancer = @@load_balancers[lb_key]?
      unless balancer
        balancer = ReplicaLoadBalancer.new([] of Grant::Adapter::Base)
        if strategy = @@database_options[spec.database]?.try(&.load_balancing_strategy)
          balancer.strategy = strategy
        end
        balancers = @@load_balancers.dup
        balancers[lb_key] = balancer
        @@load_balancers = balancers
        LoadBalancerRegistry.register(lb_key, balancer)
      end

      balancer.add_replica(adapter, HealthMonitorRegistry.get(key), key, spec.replica_weight)
    end

    private def self.unlink_replica(spec : ConnectionSpec, key : String) : Nil
      return unless spec.role == :reading

      lb_key = balancer_key(spec.database, spec.shard)
      if balancer = @@load_balancers[lb_key]?
        balancer.remove_key(key)
      end
    end

    # Returns the materialized adapter for *key*, building it lazily from its
    # stored spec on first access. Takes the registry lock only when a lazy
    # connection has to be built.
    private def self.ensure_materialized(key : String) : Grant::Adapter::Base?
      if adapter = @@adapters[key]?
        return adapter
      end
      return nil unless @@specifications.has_key?(key)

      @@mutex.synchronize do
        # Another fiber may have built it while this one waited for the lock.
        @@adapters[key]? || (@@specifications[key]?.try { |spec| materialize_adapter(spec) })
      end
    end

    # Registers many connections at once from a config hash keyed by database
    # name. Each value is a `NamedTuple` describing one database's connections.
    #
    # Per-database keys (all optional):
    #
    # * `adapter:` — the adapter class (**required** for that entry).
    # * `writer:` / `reader:` — eager writer/reader URLs (`String`), registered as
    #   the `:writing` / `:reading` roles for read/write splitting.
    # * `url:` — a single eager URL registered as the `:primary` role (use instead
    #   of `writer`/`reader` when there is no split).
    # * `writer_provider:` / `reader_provider:` / `url_provider:` — lazy
    #   `Proc(String)` equivalents, invoked once on first pool build.
    # * `pool:` — a `NamedTuple` of pool options (`max_pool_size`,
    #   `initial_pool_size`, `max_idle_pool_size`, `checkout_timeout`,
    #   `retry_attempts`, `retry_delay`).
    # * `health_check:` — a `NamedTuple` with `interval` / `timeout`.
    #
    # Each present URL/provider is forwarded to `#establish_connection`.
    #
    # ```
    # Grant::ConnectionRegistry.establish_connections({
    #   "primary" => {
    #     adapter: Grant::Adapter::Pg,
    #     writer:  "postgres://localhost/app",
    #     reader:  "postgres://replica/app",
    #     pool:    {max_pool_size: 25},
    #   },
    # })
    # ```
    def self.establish_connections(config : Hash(String, NamedTuple))
      config.each do |database, settings|
        # Extract settings with defaults
        adapter = settings[:adapter].as(Adapter::Base.class)

        # Extract pool settings if provided
        pool_config = settings[:pool]?.as?(NamedTuple)
        options = {
          pool_size:             pool_config.try(&.[:max_pool_size]?.as?(Int32)) || 25,
          initial_pool_size:     pool_config.try(&.[:initial_pool_size]?.as?(Int32)) || 2,
          max_idle_pool_size:    pool_config.try(&.[:max_idle_pool_size]?.as?(Int32)),
          checkout_timeout:      pool_config.try(&.[:checkout_timeout]?.as?(Time::Span)) || 5.seconds,
          retry_attempts:        pool_config.try(&.[:retry_attempts]?.as?(Int32)) || 1,
          retry_delay:           pool_config.try(&.[:retry_delay]?.as?(Time::Span)) || 0.2.seconds,
          health_check_interval: settings[:health_check]?.as?(NamedTuple).try(&.[:interval]?.as?(Time::Span)) || 30.seconds,
          health_check_timeout:  settings[:health_check]?.as?(NamedTuple).try(&.[:timeout]?.as?(Time::Span)) || 5.seconds,
        }

        if writer_url = settings[:writer]?.as?(String)
          establish_connection(**options, database: database, adapter: adapter, url: writer_url, role: :writing)
        end

        if reader_url = settings[:reader]?.as?(String)
          establish_connection(**options, database: database, adapter: adapter, url: reader_url, role: :reading)
        end

        # Single connection (no reader/writer split)
        if url = settings[:url]?.as?(String)
          establish_connection(**options, database: database, adapter: adapter, url: url, role: :primary)
        end

        # Lazy URL provider variants. A device/desktop config can supply a
        # `url_provider: -> String` (and/or `writer_provider`/`reader_provider`)
        # whose proc is invoked once on first pool build rather than now.
        if writer_provider = settings[:writer_provider]?.as?(Proc(String))
          establish_connection(**options, database: database, adapter: adapter, url_provider: writer_provider, role: :writing)
        end

        if reader_provider = settings[:reader_provider]?.as?(Proc(String))
          establish_connection(**options, database: database, adapter: adapter, url_provider: reader_provider, role: :reading)
        end

        if url_provider = settings[:url_provider]?.as?(Proc(String))
          establish_connection(**options, database: database, adapter: adapter, url_provider: url_provider, role: :primary)
        end
      end
    end

    # Resolves and returns the `Grant::Adapter::Base` for *database* / *role* /
    # *shard*, applying load balancing and failover.
    #
    # Lazily materializes a `url_provider:` connection on first use. For the
    # `:reading` role it draws a healthy replica from the load balancer. Every
    # role is health checked: an unhealthy connection is skipped in favor of
    # the next one in its fallback chain (reading -> writing -> primary, any
    # other role -> primary), and when nothing in the chain is healthy the
    # requested connection is returned so the caller sees the real error.
    # Raises `Grant::AdapterNotAvailableError` (the actionable guard-rail
    # error) when nothing can be resolved. This is the method models call through
    # `ConnectionManagement#adapter`.
    #
    # The lookup takes no lock unless a lazy connection has to be built.
    #
    # ```
    # writer = Grant::ConnectionRegistry.get_adapter("primary", :writing)
    # reader = Grant::ConnectionRegistry.get_adapter("primary", :reading)
    # ```
    def self.get_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Grant::Adapter::Base
      key = key_for(database, role, shard)

      # Materialize this connection lazily if it was registered with a URL
      # provider and has not been built yet. This is the "first pool build"
      # at which a lazy URL provider is invoked.
      requested = ensure_materialized(key)

      if role == :reading
        if load_balancer = @@load_balancers[balancer_key(database, shard)]?
          if replica = load_balancer.next_replica
            return replica
          end
          # No healthy replica: fall through to the writer.
        elsif requested && healthy?(key)
          return requested
        end
      elsif requested && healthy?(key)
        return requested
      end

      resolve_fallback(database, role, shard, requested) ||
        raise_adapter_not_available(database, role, shard, key)
    end

    # True unless *key*'s health monitor reports it unhealthy.
    private def self.healthy?(key : String) : Bool
      monitor = HealthMonitorRegistry.get(key)
      monitor.nil? || monitor.healthy?
    end

    # Walks the fallback chain for *role* and returns the first healthy
    # connection, else *requested*, else the first connection that exists.
    private def self.resolve_fallback(database : String, role : Symbol, shard : Symbol?, requested : Grant::Adapter::Base?) : Grant::Adapter::Base?
      chain = case role
              when :reading then [:writing, :primary]
              when :primary then [] of Symbol
              else               [:primary]
              end

      first_existing = requested
      chain.each do |fallback_role|
        key = key_for(database, fallback_role, shard)
        next unless candidate = ensure_materialized(key)
        return candidate if healthy?(key)
        first_existing ||= candidate
      end

      first_existing
    end

    # Builds the clear, actionable guard-rail error raised when a model resolves
    # an adapter for a connection that was never established. Names the
    # connection, the active build target, and the adapters that were actually
    # compiled in, so the fix is unambiguous.
    private def self.raise_adapter_not_available(database : String, role : Symbol, shard : Symbol?, key : String) : NoReturn
      targets = Grant.active_targets
      target_desc = targets.empty? ? "none (no grant/target/<name> required)" : targets.join(", ")

      compiled = Grant.compiled_adapters
      compiled_desc = compiled.empty? ? "none (no adapter shard was required — add require \"grant/adapter/<name>\")" : compiled.join(", ")

      registered = @@specifications.keys
      registered_desc = registered.empty? ? "none" : registered.join(", ")

      raise Grant::AdapterNotAvailableError.new(
        String.build do |msg|
          msg << "No database adapter is available for connection '#{database}'"
          msg << " (role: #{role}"
          msg << ", shard: #{shard}" if shard
          msg << ", key: #{key}).\n"
          msg << "  Active build target(s): #{target_desc}\n"
          msg << "  Adapters compiled in:   #{compiled_desc}\n"
          msg << "  Registered connections: #{registered_desc}\n"
          msg << "Fix: ensure this build entrypoint establishes the '#{database}' connection "
          msg << "with Grant::ConnectionRegistry.establish_connection, "
          msg << "and that the matching adapter is compiled in (require \"grant/adapter/<name>\")."
        end
      )
    end

    # Resolves the adapter for *database* / *role* / *shard* (via `#get_adapter`)
    # and yields it to the block, returning the block's value.
    #
    # ```
    # rows = Grant::ConnectionRegistry.with_adapter("primary", :reading) do |db|
    #   db.open { |conn| conn.query_all("SELECT id FROM users", as: Int64) }
    # end
    # ```
    def self.with_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil, &)
      adapter = get_adapter(database, role, shard)
      yield adapter
    end

    # Returns every materialized `Grant::Adapter::Base` belonging to *database*
    # (all roles and shards), as an `Array`.
    #
    # ```
    # Grant::ConnectionRegistry.adapters_for_database("primary") # => [adapter, ...]
    # ```
    def self.adapters_for_database(database : String) : Array(Grant::Adapter::Base)
      prefix = "#{database}:"
      @@adapters.compact_map { |key, adapter| adapter if key.starts_with?(prefix) }
    end

    # Returns the `Array(String)` of connection keys for every materialized
    # adapter (e.g. `["primary:writing", "primary:reading"]`).
    #
    # ```
    # Grant::ConnectionRegistry.adapter_names # => ["primary:primary"]
    # ```
    def self.adapter_names : Array(String)
      @@adapters.keys
    end

    # Returns the default database name (`String`) — the first connection
    # registered. Raises if no connection has been established.
    #
    # ```
    # Grant::ConnectionRegistry.default_database # => "primary"
    # ```
    def self.default_database : String
      @@default_database || raise "No default database configured"
    end

    # Overrides the default database name with *name*.
    #
    # ```
    # Grant::ConnectionRegistry.default_database = "analytics"
    # ```
    def self.default_database=(name : String)
      @@default_database = name
    end

    # Returns `true` when a connection for *database* / *role* / *shard* has been
    # established. Lazily-registered connections count as existing even before
    # their `url_provider` has run (an un-materialized spec is still
    # established), so the guard rail does not false-fire on a device target that
    # has registered but not yet queried.
    #
    # ```
    # Grant::ConnectionRegistry.connection_exists?("primary")           # => true
    # Grant::ConnectionRegistry.connection_exists?("primary", :reading) # => false
    # ```
    def self.connection_exists?(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Bool
      key = key_for(database, role, shard)
      @@adapters.has_key?(key) || @@specifications.has_key?(key)
    end

    # Returns the `Array(String)` of distinct database names that have at least
    # one registered connection spec.
    #
    # ```
    # Grant::ConnectionRegistry.databases # => ["primary", "analytics"]
    # ```
    def self.databases : Array(String)
      @@specifications.values.map(&.database).uniq
    end

    # Returns the `Array(Symbol)` of distinct shard names registered for
    # *database*, or an empty array when it is unsharded.
    #
    # ```
    # Grant::ConnectionRegistry.shards_for_database("primary") # => [:shard_one, :shard_two]
    # ```
    def self.shards_for_database(database : String) : Array(Symbol)
      @@specifications.values
        .select { |spec| spec.database == database && spec.shard }
        .compact_map(&.shard)
        .uniq
    end

    # Returns one health record per registered connection — an `Array` of
    # `NamedTuple(key, healthy, database, role)`. A connection with no health
    # monitor is reported as healthy.
    #
    # ```
    # Grant::ConnectionRegistry.health_status
    # # => [{key: "primary:primary", healthy: true, database: "primary", role: :primary}]
    # ```
    def self.health_status : Array(NamedTuple(key: String, healthy: Bool, database: String, role: Symbol))
      @@specifications.map do |key, spec|
        {
          key:      key,
          healthy:  healthy?(key),
          database: spec.database,
          role:     spec.role,
        }
      end
    end

    # Returns the `ReplicaLoadBalancer` for *database* (and optional *shard*), or
    # `nil` when no reading replicas are registered for it.
    #
    # ```
    # lb = Grant::ConnectionRegistry.get_load_balancer("primary")
    # ```
    def self.get_load_balancer(database : String, shard : Symbol? = nil) : ReplicaLoadBalancer?
      @@load_balancers[balancer_key(database, shard)]?
    end

    # Sets how reads spread across *database*'s replicas: `RoundRobinStrategy`
    # (the default), `RandomStrategy`, `LeastConnectionsStrategy` or
    # `WeightedStrategy`. It can be called before the replicas exist.
    #
    # ```
    # Grant::ConnectionRegistry.load_balancing_strategy("primary", Grant::LeastConnectionsStrategy.new)
    # ```
    def self.load_balancing_strategy(database : String, strategy : LoadBalancingStrategy, shard : Symbol? = nil) : Nil
      configure_database(database, load_balancing_strategy: strategy)
      if balancer = get_load_balancer(database, shard)
        balancer.strategy = strategy
      end
    end

    # Records settings for every connection of *database*, current and future:
    # the connect/lost-read *retry_attempts*, the *health_check_interval*, and
    # the replica *load_balancing_strategy*. Models call this when their
    # `failover_retry_attempts`, `health_check_interval` or
    # `load_balancing_strategy` is set.
    def self.configure_database(
      database : String,
      retry_attempts : Int32? = nil,
      health_check_interval : Time::Span? = nil,
      load_balancing_strategy : LoadBalancingStrategy? = nil,
    ) : Nil
      restart = [] of ConnectionSpec
      @@mutex.synchronize do
        previous = @@database_options[database]? || DatabaseOptions.new
        options = DatabaseOptions.new(
          retry_attempts: retry_attempts || previous.retry_attempts,
          health_check_interval: health_check_interval || previous.health_check_interval,
          load_balancing_strategy: load_balancing_strategy || previous.load_balancing_strategy
        )
        declared = @@database_options.dup
        declared[database] = options
        @@database_options = declared

        specifications = @@specifications.dup
        @@specifications.each do |key, spec|
          next unless spec.database == database
          spec.retry_attempts = retry_attempts if retry_attempts
          spec.health_check_interval = health_check_interval if health_check_interval
          specifications[key] = spec
          if adapter = @@adapters[key]?
            adapter.retry_attempts = spec.retry_attempts
            restart << spec if health_check_interval
          end
        end
        @@specifications = specifications

        if strategy = load_balancing_strategy
          prefix = "#{database}:"
          @@load_balancers.each do |key, balancer|
            next unless key == database || key.starts_with?(prefix)
            balancer.strategy = strategy unless balancer.strategy.same?(strategy)
          end
        end

        restart.each do |spec|
          if adapter = @@adapters[spec.connection_key]?
            HealthMonitorRegistry.register(spec.connection_key, adapter, spec)
          end
        end
      end
    end

    # Returns `true` when every monitored connection is currently healthy.
    #
    # ```
    # Grant::ConnectionRegistry.system_healthy? # => true
    # ```
    def self.system_healthy? : Bool
      HealthMonitorRegistry.all_healthy?
    end

    # Probes *database*'s connection now with `SELECT 1`, records the result in
    # its health monitor (so a recovered connection is used again at once) and
    # raises `Grant::ConnectionFailed` when it did not answer. Raises
    # `Grant::AdapterNotAvailableError` when the connection was never
    # established.
    #
    # ```
    # Grant::ConnectionRegistry.verify!("primary", :writing)
    # ```
    def self.verify!(database : String, role : Symbol = :writing, shard : Symbol? = nil, replica_index : Int32 = 0) : Nil
      key = key_for(database, role, shard, replica_index)
      adapter = ensure_materialized(key) || raise_adapter_not_available(database, role, shard, key)

      if monitor = HealthMonitorRegistry.get(key)
        monitor.verify!
      else
        adapter.verify!
      end
    end

    # Checks, once, that every connection *model* declared with `connects_to`
    # is established in the registry, and raises
    # `Grant::UnestablishedConnectionError` naming each one that is not.
    # Declaring a connection never consults the registry (models load before an
    # application establishes its connections), so call this at boot, after
    # `establish_connection`. It reads registry keys only and opens no pool.
    #
    # ```
    # Grant::ConnectionRegistry.verify!(User)
    # ```
    def self.verify!(model : Grant::Base.class) : Nil
      model.verify_connections!
    end

    # `verify!` for every model that called `connects_to`, in one error.
    def self.verify_all! : Nil
      Grant::ConnectionHandling.verify_all!
    end

    # True when *database*'s connection is established and answers `SELECT 1`.
    # A connection that was never established, or whose server is down, is
    # `false`; it never raises.
    def self.connected?(database : String, role : Symbol = :writing, shard : Symbol? = nil, replica_index : Int32 = 0) : Bool
      key = key_for(database, role, shard, replica_index)
      return false unless adapter = ensure_materialized(key)

      adapter.active?
    end

    # Returns the `Grant::ConnectionPool` for *database* / *role* / *shard*, or
    # `nil` when that connection was never established. It does not fall back to
    # another role.
    def self.connection_pool(database : String, role : Symbol = :writing, shard : Symbol? = nil, replica_index : Int32 = 0) : Grant::ConnectionPool?
      adapter = ensure_materialized(key_for(database, role, shard, replica_index))
      adapter ? Grant::ConnectionPool.new(adapter) : nil
    end

    # Returns the `ConnectionSpec` *database* / *role* / *shard* was registered
    # with, or `nil` when it was never established.
    def self.connection_spec(database : String, role : Symbol = :writing, shard : Symbol? = nil, replica_index : Int32 = 0) : ConnectionSpec?
      @@specifications[key_for(database, role, shard, replica_index)]?
    end

    # Returns pool statistics for every open connection, or for the one whose
    # registry key is *key*. It reads the registry's immutable snapshot and the
    # pools' own counters and takes no lock.
    #
    # ```
    # Grant::ConnectionRegistry.pool_stats("primary:writing")
    # # => [{key: "primary:writing", open: 3, idle: 2, in_flight: 0, max: 25}]
    # ```
    def self.pool_stats(key : String? = nil) : Array(NamedTuple(key: String, open: Int32, idle: Int32, in_flight: Int32, max: Int32))
      adapters = @@adapters
      selected = key ? adapters.select { |name, _| name == key } : adapters
      selected.map do |name, adapter|
        stat = adapter.pool_stat
        {key: name, open: stat.connections, idle: stat.idle, in_flight: stat.in_flight, max: stat.size}
      end
    end

    # Removes one connection: unlinks it from the registry (and from its
    # database's load balancer), stops its health monitor and reaper, then
    # closes its pool. Returns `false` when there was no such connection. The
    # pool is closed after the registry lock is released.
    #
    # ```
    # Grant::ConnectionRegistry.remove_connection("primary", :reading, replica_index: 1)
    # ```
    def self.remove_connection(database : String, role : Symbol = :writing, shard : Symbol? = nil, replica_index : Int32 = 0) : Bool
      key = key_for(database, role, shard, replica_index)
      removed = nil
      found = false

      @@mutex.synchronize do
        spec = @@specifications[key]?
        removed = @@adapters[key]?
        found = !spec.nil? || !removed.nil?

        if found
          specifications = @@specifications.dup
          specifications.delete(key)
          @@specifications = specifications

          adapters = @@adapters.dup
          adapters.delete(key)
          @@adapters = adapters

          reapers = @@reapers.dup
          reapers.delete(key).try(&.stop)
          @@reapers = reapers

          if role == :reading
            lb_key = balancer_key(database, shard)
            if balancer = @@load_balancers[lb_key]?
              balancer.remove_key(key)
              if balancer.size == 0
                balancers = @@load_balancers.dup
                balancers.delete(lb_key)
                @@load_balancers = balancers
                LoadBalancerRegistry.unregister(lb_key)
              end
            end
          end
        end
      end

      return false unless found

      HealthMonitorRegistry.unregister(key)
      removed.try(&.disconnect!)
      true
    end

    # Closes every pool but keeps the connections registered: each reopens on
    # next use. This is ActiveRecord's `clear_all_connections!`.
    #
    # ```
    # Grant::ConnectionRegistry.disconnect_all!
    # ```
    def self.disconnect_all! : Nil
      @@adapters.each_value(&.disconnect!)
    end

    # Tears down all connection state: stops health monitors and reapers, clears
    # load balancers, closes every pool, and drops every adapter, specification,
    # and the default database. Used between specs. Settings declared with
    # `#configure_database` (a model's strategy, retry count and health check
    # interval) describe the application, not a connection, so they stay.
    #
    # ```
    # Grant::ConnectionRegistry.clear_all # reset the registry completely
    # ```
    def self.clear_all
      retired = [] of Grant::Adapter::Base
      reapers = nil

      @@mutex.synchronize do
        retired.concat(@@adapters.values)
        reapers = @@reapers

        @@adapters = {} of String => Grant::Adapter::Base
        @@specifications = {} of String => ConnectionSpec
        @@load_balancers = {} of String => ReplicaLoadBalancer
        @@reapers = {} of String => PoolReaper
        @@default_database = nil
      end

      # Stopping monitors and closing pools happens outside the lock.
      HealthMonitorRegistry.clear
      LoadBalancerRegistry.clear
      reapers.try(&.each_value(&.stop))
      retire(retired)
    end
  end
end
