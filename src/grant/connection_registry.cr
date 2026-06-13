require "./health_monitor"
require "./replica_load_balancer"

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
  class AdapterNotAvailableError < Exception
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
      # result is memoised into `@url`. Device targets that compute their DB
      # path at runtime (e.g. an app-support directory only known after boot)
      # register with this instead of an eager URL.
      @url_provider : (-> String)?

      # Pool configuration
      property pool_size : Int32 = 25
      property initial_pool_size : Int32 = 2
      property checkout_timeout : Time::Span = 5.seconds
      property retry_attempts : Int32 = 1
      property retry_delay : Time::Span = 0.2.seconds

      # Health check configuration
      property health_check_interval : Time::Span = 30.seconds
      property health_check_timeout : Time::Span = 5.seconds

      def initialize(@database, @adapter_class, url : String, @role, @shard = nil,
                     @pool_size = 25, @initial_pool_size = 2,
                     @checkout_timeout = 5.seconds, @retry_attempts = 1,
                     @retry_delay = 0.2.seconds, @health_check_interval = 30.seconds,
                     @health_check_timeout = 5.seconds)
        @url = url
        @url_provider = nil
      end

      # Lazy-URL constructor. The provider is *not* invoked here; it is resolved
      # on first pool build via `#resolved_url`.
      def initialize(@database, @adapter_class, @role, *, url_provider : -> String, @shard = nil,
                     @pool_size = 25, @initial_pool_size = 2,
                     @checkout_timeout = 5.seconds, @retry_attempts = 1,
                     @retry_delay = 0.2.seconds, @health_check_interval = 30.seconds,
                     @health_check_timeout = 5.seconds)
        @url = nil
        @url_provider = url_provider
      end

      # True when this spec was registered with a lazy `url_provider` and has not
      # resolved it yet.
      def lazy? : Bool
        @url.nil? && !@url_provider.nil?
      end

      # Resolves the connection URL, invoking (and memoising) the lazy provider
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
      def connection_key : String
        if shard
          "#{database}:#{role}:#{shard}"
        else
          "#{database}:#{role}"
        end
      end

      # Returns the connection URL (`String`) with the pool/retry settings
      # appended as crystal-db query parameters (`max_pool_size`,
      # `initial_pool_size`, `checkout_timeout`, `retry_attempts`,
      # `retry_delay`). Resolves a lazy `url_provider` if needed.
      def build_pool_url : String
        uri = URI.parse(resolved_url)
        params = uri.query_params

        params["max_pool_size"] = @pool_size.to_s
        params["initial_pool_size"] = @initial_pool_size.to_s
        params["checkout_timeout"] = @checkout_timeout.total_seconds.to_s
        params["retry_attempts"] = @retry_attempts.to_s
        params["retry_delay"] = @retry_delay.total_seconds.to_s

        uri.query = params.to_s
        uri.to_s
      end
    end

    # Class-level storage
    @@adapters = {} of String => Grant::Adapter::Base
    @@specifications = {} of String => ConnectionSpec
    @@load_balancers = {} of String => ReplicaLoadBalancer
    @@mutex = Mutex.new
    @@default_database : String? = nil

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
    # * *shard* — name this connection's shard for horizontal sharding, or leave
    #   `nil`.
    # * the remaining `pool_*` / `checkout_timeout` / `retry_*` /
    #   `health_check_*` arguments tune the connection pool and health checks.
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
    )
      spec = ConnectionSpec.new(
        database, adapter, url, role, shard,
        pool_size, initial_pool_size, checkout_timeout,
        retry_attempts, retry_delay, health_check_interval,
        health_check_timeout
      )
      register_spec(spec, eager: true)
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
    )
      spec = ConnectionSpec.new(
        database, adapter, role, url_provider: url_provider, shard: shard,
        pool_size: pool_size, initial_pool_size: initial_pool_size,
        checkout_timeout: checkout_timeout, retry_attempts: retry_attempts,
        retry_delay: retry_delay, health_check_interval: health_check_interval,
        health_check_timeout: health_check_timeout
      )
      # eager: false → the adapter instance (and therefore the URL provider) is
      # not materialised until first use.
      register_spec(spec, eager: false)
    end

    # Stores a spec and, when *eager* is true (or the spec carries an eager URL),
    # immediately materialises the adapter instance. Lazy specs defer adapter
    # creation — and thus URL-provider invocation — to the first `get_adapter`.
    private def self.register_spec(spec : ConnectionSpec, eager : Bool)
      key = spec.connection_key

      @@mutex.synchronize do
        # Store specification
        @@specifications[key] = spec

        # Set as default if first database
        @@default_database ||= spec.database

        # Materialise eagerly only for eager specs. Lazy specs are built on the
        # first checkout via #ensure_materialized (called from get_adapter).
        if eager && !spec.lazy?
          materialize_adapter(spec)
        end
      end
    end

    # Builds the concrete adapter instance for *spec* (resolving its URL,
    # invoking a lazy provider exactly once) and registers it, its health
    # monitor, and — for reading roles — its load-balancer entry. Must be called
    # while holding `@@mutex`.
    private def self.materialize_adapter(spec : ConnectionSpec) : Grant::Adapter::Base
      key = spec.connection_key

      # Create adapter instance with pooled URL (this resolves a lazy provider).
      adapter_instance = spec.adapter_class.new(key, spec.build_pool_url)
      @@adapters[key] = adapter_instance

      # Create and register health monitor (unless in test mode)
      unless HealthMonitor.test_mode
        HealthMonitorRegistry.register(key, adapter_instance, spec)
      end

      # Track read replicas for load balancing
      if spec.role == :reading
        lb_key = spec.shard ? "#{spec.database}:#{spec.shard}" : spec.database

        # Create load balancer if it doesn't exist
        unless @@load_balancers.has_key?(lb_key)
          @@load_balancers[lb_key] = ReplicaLoadBalancer.new([] of Grant::Adapter::Base)
          LoadBalancerRegistry.register(lb_key, @@load_balancers[lb_key])
        end

        # Add replica to load balancer
        load_balancer = @@load_balancers[lb_key]
        # Health monitor is optional
        health_monitor = HealthMonitorRegistry.get(key)
        load_balancer.add_replica(adapter_instance, health_monitor)
      end

      adapter_instance
    end

    # Returns the materialised adapter for *key*, building it lazily from its
    # stored spec on first access. Must be called while holding `@@mutex`.
    private def self.ensure_materialized(key : String) : Grant::Adapter::Base?
      if adapter = @@adapters[key]?
        return adapter
      end
      if spec = @@specifications[key]?
        return materialize_adapter(spec)
      end
      nil
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
    #   `initial_pool_size`, `checkout_timeout`, `retry_attempts`, `retry_delay`).
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
        pool_size = pool_config.try(&.[:max_pool_size]?.as?(Int32)) || 25
        initial_pool_size = pool_config.try(&.[:initial_pool_size]?.as?(Int32)) || 2
        checkout_timeout = pool_config.try(&.[:checkout_timeout]?.as?(Time::Span)) || 5.seconds
        retry_attempts = pool_config.try(&.[:retry_attempts]?.as?(Int32)) || 1
        retry_delay = pool_config.try(&.[:retry_delay]?.as?(Time::Span)) || 0.2.seconds

        # Extract health check settings
        health_config = settings[:health_check]?.as?(NamedTuple)
        health_check_interval = health_config.try(&.[:interval]?.as?(Time::Span)) || 30.seconds
        health_check_timeout = health_config.try(&.[:timeout]?.as?(Time::Span)) || 5.seconds

        # Handle writer connection
        if writer_url = settings[:writer]?.as?(String)
          establish_connection(
            database: database,
            adapter: adapter,
            url: writer_url,
            role: :writing,
            pool_size: pool_size,
            initial_pool_size: initial_pool_size,
            checkout_timeout: checkout_timeout,
            retry_attempts: retry_attempts,
            retry_delay: retry_delay,
            health_check_interval: health_check_interval,
            health_check_timeout: health_check_timeout
          )
        end

        # Handle reader connection
        if reader_url = settings[:reader]?.as?(String)
          establish_connection(
            database: database,
            adapter: adapter,
            url: reader_url,
            role: :reading,
            pool_size: pool_size,
            initial_pool_size: initial_pool_size,
            checkout_timeout: checkout_timeout,
            retry_attempts: retry_attempts,
            retry_delay: retry_delay,
            health_check_interval: health_check_interval,
            health_check_timeout: health_check_timeout
          )
        end

        # Handle single connection (no reader/writer split)
        if url = settings[:url]?.as?(String)
          establish_connection(
            database: database,
            adapter: adapter,
            url: url,
            role: :primary,
            pool_size: pool_size,
            initial_pool_size: initial_pool_size,
            checkout_timeout: checkout_timeout,
            retry_attempts: retry_attempts,
            retry_delay: retry_delay,
            health_check_interval: health_check_interval,
            health_check_timeout: health_check_timeout
          )
        end

        # Lazy URL provider variants. A device/desktop config can supply a
        # `url_provider: -> String` (and/or `writer_provider`/`reader_provider`)
        # whose proc is invoked once on first pool build rather than now.
        if writer_provider = settings[:writer_provider]?.as?(Proc(String))
          establish_connection(
            database: database, adapter: adapter, url_provider: writer_provider,
            role: :writing, pool_size: pool_size, initial_pool_size: initial_pool_size,
            checkout_timeout: checkout_timeout, retry_attempts: retry_attempts,
            retry_delay: retry_delay, health_check_interval: health_check_interval,
            health_check_timeout: health_check_timeout
          )
        end

        if reader_provider = settings[:reader_provider]?.as?(Proc(String))
          establish_connection(
            database: database, adapter: adapter, url_provider: reader_provider,
            role: :reading, pool_size: pool_size, initial_pool_size: initial_pool_size,
            checkout_timeout: checkout_timeout, retry_attempts: retry_attempts,
            retry_delay: retry_delay, health_check_interval: health_check_interval,
            health_check_timeout: health_check_timeout
          )
        end

        if url_provider = settings[:url_provider]?.as?(Proc(String))
          establish_connection(
            database: database, adapter: adapter, url_provider: url_provider,
            role: :primary, pool_size: pool_size, initial_pool_size: initial_pool_size,
            checkout_timeout: checkout_timeout, retry_attempts: retry_attempts,
            retry_delay: retry_delay, health_check_interval: health_check_interval,
            health_check_timeout: health_check_timeout
          )
        end
      end
    end

    # Resolves and returns the `Grant::Adapter::Base` for *database* / *role* /
    # *shard*, applying load balancing and failover.
    #
    # Lazily materialises a `url_provider:` connection on first use. For the
    # `:reading` role it draws a healthy replica from the load balancer when one
    # is configured; an unhealthy primary falls back via `#try_fallback_adapter`
    # (a missing role falls back to `:primary`; a missing reader falls back to the
    # writer). Raises `Grant::AdapterNotAvailableError` (the actionable guard-rail
    # error) when nothing can be resolved. This is the method models call through
    # `ConnectionManagement#adapter`.
    #
    # ```
    # writer = Grant::ConnectionRegistry.get_adapter("primary", :writing)
    # reader = Grant::ConnectionRegistry.get_adapter("primary", :reading)
    # ```
    def self.get_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Grant::Adapter::Base
      key = if shard
              "#{database}:#{role}:#{shard}"
            else
              "#{database}:#{role}"
            end

      @@mutex.synchronize do
        # Materialise this connection lazily if it was registered with a URL
        # provider and has not been built yet. This is the "first pool build"
        # at which a lazy URL provider is invoked.
        ensure_materialized(key)

        # For reading role, try load balancer first
        if role == :reading
          lb_key = shard ? "#{database}:#{shard}" : database
          if load_balancer = @@load_balancers[lb_key]?
            # Try to get a healthy replica
            if replica = load_balancer.next_replica
              return replica
            end
            # If no healthy replicas, fall through to fallback logic
          end
        end

        # Direct adapter lookup
        adapter = @@adapters[key]?

        # Check adapter health if not using load balancer (optional)
        if adapter && role != :reading
          if monitor = HealthMonitorRegistry.get(key)
            unless monitor.healthy?
              # Try fallback if primary adapter is unhealthy
              adapter = try_fallback_adapter(database, role, shard)
            end
          end
          # If no monitor registered, assume healthy
        end

        # Standard fallback logic if adapter not found
        adapter ||= try_fallback_adapter(database, role, shard)

        adapter || raise_adapter_not_available(database, role, shard, key)
      end
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

    # Try to find a fallback adapter
    private def self.try_fallback_adapter(database : String, role : Symbol, shard : Symbol?) : Grant::Adapter::Base?
      # Fallback to primary role if specific role not found
      if role != :primary
        key = shard ? "#{database}:primary:#{shard}" : "#{database}:primary"
        if adapter = ensure_materialized(key)
          # Check health before returning
          if monitor = HealthMonitorRegistry.get(key)
            return adapter if monitor.healthy?
          else
            return adapter
          end
        end
      end

      # Fallback to writer if reading not available
      if role == :reading
        key = shard ? "#{database}:writing:#{shard}" : "#{database}:writing"
        if adapter = ensure_materialized(key)
          # Check health before returning
          if monitor = HealthMonitorRegistry.get(key)
            return adapter if monitor.healthy?
          else
            return adapter
          end
        end
      end

      nil
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

    # Returns every materialised `Grant::Adapter::Base` belonging to *database*
    # (all roles and shards), as an `Array`.
    #
    # ```
    # Grant::ConnectionRegistry.adapters_for_database("primary") # => [adapter, ...]
    # ```
    def self.adapters_for_database(database : String) : Array(Grant::Adapter::Base)
      @@mutex.synchronize do
        @@adapters.select { |key, _| key.starts_with?("#{database}:") }.values
      end
    end

    # Returns the `Array(String)` of connection keys for every materialised
    # adapter (e.g. `["primary:writing", "primary:reading"]`).
    #
    # ```
    # Grant::ConnectionRegistry.adapter_names # => ["primary:primary"]
    # ```
    def self.adapter_names : Array(String)
      @@mutex.synchronize do
        @@adapters.keys
      end
    end

    # Clears materialised adapters, specifications, and the default database.
    #
    # NOTE: a second, more thorough `clear_all` defined later in this class also
    # stops health monitors and load balancers and is the one actually used;
    # prefer it for full teardown (e.g. between specs).
    def self.clear_all
      @@mutex.synchronize do
        @@adapters.clear
        @@specifications.clear
        @@default_database = nil
      end

      # All adapters cleared
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
    # their `url_provider` has run (an un-materialised spec is still
    # established), so the guard rail does not false-fire on a device target that
    # has registered but not yet queried.
    #
    # ```
    # Grant::ConnectionRegistry.connection_exists?("primary")           # => true
    # Grant::ConnectionRegistry.connection_exists?("primary", :reading) # => false
    # ```
    def self.connection_exists?(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Bool
      key = shard ? "#{database}:#{role}:#{shard}" : "#{database}:#{role}"
      @@mutex.synchronize { @@adapters.has_key?(key) || @@specifications.has_key?(key) }
    end

    # Returns the `Array(String)` of distinct database names that have at least
    # one registered connection spec.
    #
    # ```
    # Grant::ConnectionRegistry.databases # => ["primary", "analytics"]
    # ```
    def self.databases : Array(String)
      @@mutex.synchronize do
        @@specifications.values.map(&.database).uniq
      end
    end

    # Returns the `Array(Symbol)` of distinct shard names registered for
    # *database*, or an empty array when it is unsharded.
    #
    # ```
    # Grant::ConnectionRegistry.shards_for_database("primary") # => [:shard_one, :shard_two]
    # ```
    def self.shards_for_database(database : String) : Array(Symbol)
      @@mutex.synchronize do
        @@specifications.values
          .select { |spec| spec.database == database && spec.shard }
          .map(&.shard.not_nil!)
          .uniq
      end
    end

    # Pool configuration is now handled by crystal-db URL parameters

    # Returns one health record per registered connection — an `Array` of
    # `NamedTuple(key, healthy, database, role)`. A connection with no health
    # monitor is reported as healthy.
    #
    # ```
    # Grant::ConnectionRegistry.health_status
    # # => [{key: "primary:primary", healthy: true, database: "primary", role: :primary}]
    # ```
    def self.health_status : Array(NamedTuple(key: String, healthy: Bool, database: String, role: Symbol))
      @@mutex.synchronize do
        @@specifications.map do |key, spec|
          monitor = HealthMonitorRegistry.get(key)
          {
            key:      key,
            healthy:  monitor.nil? || monitor.healthy?,
            database: spec.database,
            role:     spec.role,
          }
        end
      end
    end

    # Returns the `ReplicaLoadBalancer` for *database* (and optional *shard*), or
    # `nil` when no reading replicas are registered for it.
    #
    # ```
    # lb = Grant::ConnectionRegistry.get_load_balancer("primary")
    # ```
    def self.get_load_balancer(database : String, shard : Symbol? = nil) : ReplicaLoadBalancer?
      lb_key = shard ? "#{database}:#{shard}" : database
      @@mutex.synchronize { @@load_balancers[lb_key]? }
    end

    # Returns `true` when every monitored connection is currently healthy.
    #
    # ```
    # Grant::ConnectionRegistry.system_healthy? # => true
    # ```
    def self.system_healthy? : Bool
      HealthMonitorRegistry.all_healthy?
    end

    # Tears down all connection state: stops health monitors, clears load
    # balancers, and drops every adapter, specification, and the default
    # database. This is the full-teardown variant (used between specs); it
    # overrides the earlier, lighter `clear_all` defined above.
    #
    # ```
    # Grant::ConnectionRegistry.clear_all # reset the registry completely
    # ```
    def self.clear_all
      @@mutex.synchronize do
        # Stop all health monitors
        HealthMonitorRegistry.clear

        # Clear load balancers
        LoadBalancerRegistry.clear
        @@load_balancers.clear

        # Clear adapters and specs
        @@adapters.clear
        @@specifications.clear
        @@default_database = nil
      end
    end
  end
end
