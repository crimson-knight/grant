require "./connection_registry"

# Multi-database connection management, mixed into every `Grant::Base` model.
#
# Provides the DSL and runtime for: choosing a model's default connection
# (`connection` / `connects_to`), automatic read/write splitting across primary
# and replica connections, horizontal sharding, read-only windows, and the
# write-tracking that decides when a replica is safe to read. The public entry
# points are the `connects_to` / `connection` / `connection_config` macros and
# the `ClassMethods` (`connected_to`, `while_preventing_writes`, `current_role`,
# `adapter`, etc.). Named connections themselves are established via
# `Grant::ConnectionRegistry.establish_connection`.
module Grant::ConnectionManagement
  # Snapshot of a fiber's active connection context: which database, role, and
  # shard a unit of work is targeting, and whether writes are prevented.
  #
  # Pushed and popped by `ClassMethods#connected_to`; you generally read it
  # indirectly via `current_database` / `current_role` / `current_shard` /
  # `preventing_writes?` rather than constructing one yourself.
  struct ConnectionContext
    # The target database (connection) name.
    property database : String
    # The target role (`:primary`, `:writing`, `:reading`, ...).
    property role : Symbol
    # The target shard, or `nil` for the unsharded connection.
    property shard : Symbol?
    # When true, writes raise `Grant::Transaction::ReadOnlyError`.
    property prevent_writes : Bool

    def initialize(@database, @role = :primary, @shard = nil, @prevent_writes = false)
    end
  end

  # Per database/shard bookkeeping for the read/write splitter: when the last
  # write happened, an optional "stick to primary until" deadline, and the lag
  # threshold. Drives the decision of whether a read may safely use a replica.
  struct ReplicaLagTracker
    # Monotonic timestamp of the most recent tracked write.
    property last_write_time : Time::Span
    # Monotonic deadline before which reads must use the primary, or `nil`.
    property sticky_until : Time::Span?
    # How stale a replica may be before reads return to the primary.
    property lag_threshold : Time::Span

    def initialize(@last_write_time = Time.monotonic,
                   @sticky_until = nil,
                   @lag_threshold = 2.seconds)
    end

    # Records a write now, resetting `last_write_time` to the current monotonic
    # clock so the post-write quiet period starts over.
    #
    # ```
    # tracker.mark_write
    # ```
    def mark_write
      @last_write_time = Time.monotonic
    end

    # Forces reads onto the primary for the next *duration* by setting
    # `sticky_until` to now + *duration*.
    #
    # ```
    # tracker.stick_to_primary(5.seconds)
    # ```
    def stick_to_primary(duration : Time::Span)
      @sticky_until = Time.monotonic + duration
    end

    # Returns `true` when a replica may be read from: there is no active sticky
    # window AND at least *wait_period* has elapsed since the last write.
    #
    # ```
    # tracker.can_use_replica?(2.seconds) # => true once 2s have passed write-free
    # ```
    def can_use_replica?(wait_period : Time::Span) : Bool
      now = Time.monotonic

      # Check if we're in sticky period
      if sticky = @sticky_until
        return false if now < sticky
      end

      # Check if enough time has passed since last write
      now - @last_write_time > wait_period
    end
  end

  macro included
    # Connection configuration
    class_property database_name : String = "primary"
    class_property connection_config = {} of Symbol => String
    class_property shard_config = {} of Symbol => Hash(Symbol, String)

    # Fiber-keyed connection context — one slot per fiber so concurrent fibers
    # that each call connected_to cannot corrupt each other's role/database/shard.
    # No mutex: safe under Crystal's default single-threaded fiber scheduler;
    # would need synchronization under -Dpreview_mt (as ShardManager's config
    # hash already has).
    @@connection_contexts = {} of Fiber => ConnectionContext

    # Returns the current fiber's `ConnectionContext`, or `nil` when no
    # `#connected_to` block is active (the default primary/writing context).
    #
    # ```
    # User.connection_context # => nil (outside any connected_to block)
    # ```
    def self.connection_context : ConnectionContext?
      @@connection_contexts[Fiber.current]?
    end

    # Sets (or with `nil`, clears) the current fiber's `ConnectionContext`.
    # Managed by `#connected_to`; you rarely call it directly. Passing `nil`
    # deletes the fiber's entry to avoid leaking context on long-lived fibers.
    def self.connection_context=(ctx : ConnectionContext?)
      if ctx.nil?
        # Delete the entry rather than storing nil — avoids a memory leak
        # where long-lived fibers accumulate dead entries.
        @@connection_contexts.delete(Fiber.current)
      else
        @@connection_contexts[Fiber.current] = ctx
      end
    end

    # Enhanced replica lag tracking per database/shard
    class_property replica_lag_trackers = {} of String => ReplicaLagTracker

    # Connection behavior configuration
    class_property replica_lag_threshold : Time::Span = 2.seconds
    class_property failover_retry_attempts : Int32 = 3
    class_property health_check_interval : Time::Span = 30.seconds
  end

  # Declares which database(s), roles, and shards a model connects to.
  #
  # All three arguments are optional:
  #
  # * *database* — the default connection name (a `String`). Sets
  #   `database_name`, the connection used when no role/shard override is active.
  # * *config* — a `NamedTuple` of `role => connection_name`, e.g.
  #   `{writing: "primary", reading: "primary_replica"}`. Enables automatic
  #   read/write splitting: reads route to the `:reading` connection once enough
  #   time has passed since the last write (see `#stick_to_primary`).
  # * *shards* — a `NamedTuple` of `shard_name => {role => connection_name}` for
  #   horizontal sharding. Switch the active shard at runtime with
  #   `#connected_to(shard: ...)`.
  #
  # The named connections themselves must be established separately with
  # `Grant::ConnectionRegistry.establish_connection`.
  #
  # ```
  # class User < Grant::Base
  #   connects_to(
  #     database: "primary",
  #     config: {writing: "primary", reading: "primary_replica"},
  #     shards: {
  #       shard_one: {writing: "shard_one", reading: "shard_one_replica"},
  #       shard_two: {writing: "shard_two", reading: "shard_two_replica"},
  #     }
  #   )
  # end
  # ```
  macro connects_to(database = nil, config = nil, shards = nil)
    {% if database %}
      self.database_name = {{database}}
    {% end %}
    
    {% if config %}
      {% if config.is_a?(NamedTupleLiteral) %}
        self.connection_config = {
          {% for role, db_name in config %}
            {{role.id.symbolize}} => {{db_name.id.stringify}},
          {% end %}
        } of Symbol => String
      {% end %}
    {% end %}
    
    {% if shards %}
      {% if shards.is_a?(NamedTupleLiteral) %}
        self.shard_config = {
          {% for shard_name, shard_settings in shards %}
            {{shard_name.id.symbolize}} => {
              {% for role, db_name in shard_settings %}
                {{role.id.symbolize}} => {{db_name.id.stringify}},
              {% end %}
            } of Symbol => String,
          {% end %}
        } of Symbol => Hash(Symbol, String)
      {% end %}
    {% end %}
  end

  # Configures connection behavior on the model from keyword *options*.
  #
  # Recognized keys (each maps to the matching `class_property`):
  #
  # * `replica_lag_threshold : Time::Span` — how stale a replica may be before
  #   reads are forced back to the primary.
  # * `failover_retry_attempts : Int32` — retry count before giving up on a
  #   connection.
  # * `health_check_interval : Time::Span` — how often health checks run.
  # * `connection_switch_wait_period` — quiet period after a write before reads
  #   may use a replica.
  # * `load_balancing_strategy` — replica selection strategy.
  #
  # Any other key is a compile-time error.
  #
  # ```
  # class User < Grant::Base
  #   connection_config(
  #     replica_lag_threshold: 2.seconds,
  #     failover_retry_attempts: 3
  #   )
  # end
  # ```
  macro connection_config(**options)
    {% for key, value in options %}
      {% if key == :replica_lag_threshold %}
        self.replica_lag_threshold = {{value}}
      {% elsif key == :failover_retry_attempts %}
        self.failover_retry_attempts = {{value}}
      {% elsif key == :health_check_interval %}
        self.health_check_interval = {{value}}
      {% elsif key == :connection_switch_wait_period %}
        self.connection_switch_wait_period = {{value}}
      {% elsif key == :load_balancing_strategy %}
        self.load_balancing_strategy = {{value}}
      {% else %}
        {% raise "Unknown connection config option: #{key}" %}
      {% end %}
    {% end %}
  end

  module ClassMethods
    # Raises `Grant::Transaction::ReadOnlyError` when the current fiber is in a
    # write-preventing context (see `#while_preventing_writes` /
    # `#connected_to(prevent_writes: true)`); otherwise returns `nil` and does
    # nothing.
    #
    # Grant calls this at the start of every mutation path so read-only contexts
    # are actually enforced. You rarely call it directly, but it's available if
    # you add a custom mutation method.
    #
    # ```
    # User.while_preventing_writes do
    #   User.guard_writes! # raises Grant::Transaction::ReadOnlyError
    # end
    # ```
    def guard_writes!
      if preventing_writes?
        raise Grant::Transaction::ReadOnlyError.new(
          "Write query attempted while in readonly mode: #{name}"
        )
      end
    end

    # Returns the global quiet period (in milliseconds) after a write during
    # which reads stay on the primary before a replica may be used. Delegates to
    # `Grant::Connections` for backward compatibility.
    #
    # ```
    # User.connection_switch_wait_period # => 2000
    # ```
    def connection_switch_wait_period
      Grant::Connections.connection_switch_wait_period
    end

    # Sets the global post-write quiet period to *value* milliseconds. After a
    # write, reads route to the primary until this many milliseconds have
    # elapsed. Delegates to `Grant::Connections`.
    #
    # ```
    # User.connection_switch_wait_period = 5000 # 5s of read-your-writes
    # ```
    def connection_switch_wait_period=(value : Int32)
      Grant::Connections.connection_switch_wait_period = value
    end

    # Runs the block with a temporary connection context — switching the
    # *database*, *role*, *shard*, and/or write-prevention — and restores the
    # previous context afterward (even on exception). Returns the block's value.
    #
    # Each argument defaults to `nil`/`false`, meaning "keep the current value".
    # The context is fiber-local, so concurrent fibers do not interfere. This is
    # the primary way to target a replica, a specific shard, or a read-only
    # window for a unit of work.
    #
    # ```
    # # force reads through the replica for this block
    # users = User.connected_to(role: :reading) { User.where(active: true).select }
    #
    # # target a specific shard
    # User.connected_to(shard: :shard_two) { User.find(id) }
    #
    # # read-only window
    # User.connected_to(role: :reading, prevent_writes: true) { report.run }
    # ```
    def connected_to(
      database : String? = nil,
      role : Symbol? = nil,
      shard : Symbol? = nil,
      prevent_writes : Bool = false,
      &
    )
      # Save current context
      previous_context = connection_context
      previous_database = database_name if database

      # Create new context
      self.connection_context = ConnectionContext.new(
        database || current_database,
        role || current_role,
        shard || current_shard,
        prevent_writes || preventing_writes?
      )

      # Update database name if provided
      self.database_name = database if database

      yield
    ensure
      # Restore previous context
      self.connection_context = previous_context
      self.database_name = previous_database if database && previous_database
    end

    # Returns the name (`String`) of the database the model is currently using —
    # the active `#connected_to` context's database if one is set, otherwise the
    # model's default `database_name`.
    #
    # ```
    # User.current_database                                              # => "primary"
    # User.connected_to(database: "analytics") { User.current_database } # => "analytics"
    # ```
    def current_database : String
      connection_context.try(&.database) || database_name
    end

    # Returns the connection role (`Symbol`) currently in effect: an explicit
    # `#connected_to(role: ...)` override, `:reading` when automatic read/write
    # splitting routes this read to a replica, or `:primary` by default.
    #
    # ```
    # User.current_role                                       # => :primary
    # User.connected_to(role: :reading) { User.current_role } # => :reading
    # ```
    def current_role : Symbol
      return :reading if should_use_reader?
      connection_context.try(&.role) || :primary
    end

    # Returns the active shard as a `Symbol`, or `nil` when no shard is selected
    # (the unsharded / default case). Set the shard for a block with
    # `#connected_to(shard: ...)`.
    #
    # ```
    # User.current_shard                                          # => nil
    # User.connected_to(shard: :shard_two) { User.current_shard } # => :shard_two
    # ```
    def current_shard : Symbol?
      connection_context.try(&.shard)
    end

    # Returns `true` when the current fiber is in a write-preventing context
    # (e.g. inside `#while_preventing_writes` or
    # `#connected_to(prevent_writes: true)`), `false` otherwise.
    #
    # ```
    # User.preventing_writes?                                  # => false
    # User.while_preventing_writes { User.preventing_writes? } # => true
    # ```
    def preventing_writes? : Bool
      connection_context.try(&.prevent_writes) || false
    end

    # Runs the block in a write-preventing context: any attempted write raises
    # `Grant::Transaction::ReadOnlyError` (via `#guard_writes!`). Returns the
    # block's value and restores the previous context afterward. A convenience
    # wrapper over `#connected_to(prevent_writes: true)`.
    #
    # ```
    # User.while_preventing_writes do
    #   User.find(id)    # ok
    #   User.create(...) # raises Grant::Transaction::ReadOnlyError
    # end
    # ```
    def while_preventing_writes(&)
      connected_to(prevent_writes: true) do
        yield
      end
    end

    # Returns the `Grant::Adapter::Base` the model should use right now, resolving
    # the active database/role/shard context through `ConnectionRegistry`.
    #
    # Sharded connections look up the database for the current shard+role;
    # role-based connections resolve via `connection_config`; otherwise the
    # default database is used. For backward compatibility, if the resolved
    # connection was never established but exactly one global connection exists,
    # that connection's writer is returned; if nothing is registered at all, the
    # `Grant::AdapterNotAvailableError` guard-rail propagates.
    #
    # ```
    # User.adapter                                       # => the primary adapter
    # User.connected_to(role: :reading) { User.adapter } # => the replica adapter
    # ```
    def adapter : Grant::Adapter::Base
      # Determine database name
      db_name = if shard = current_shard
                  # For sharded connections, look up the database name
                  shard_settings = shard_config[shard]?
                  shard_settings.try(&.[current_role]?) || current_database
                elsif role_db = connection_config[current_role]?
                  # For role-based connections
                  role_db
                else
                  # Default database
                  current_database
                end

      begin
        ConnectionRegistry.get_adapter(db_name, current_role, current_shard)
      rescue ex : Grant::AdapterNotAvailableError
        # Fallback to first registered connection for backward compatibility.
        # This handles legacy setups where a model references a connection name
        # that was not explicitly registered but a single global connection
        # exists (the common test/dev case). If there is genuinely nothing
        # registered, re-raise the clear, target-aware guard-rail error from
        # get_adapter rather than masking it with a generic string.
        if (reg = Grant::Connections.registered_connections) && (conn = reg.first?)
          conn[:writer]
        else
          raise ex
        end
      end
    end

    # Returns the monotonic `Time::Span` timestamp of the most recent write
    # tracked for the current database/shard. Used by the read/write splitter to
    # decide when a replica is safe to read from after a write.
    #
    # ```
    # User.create(name: "Ada")
    # User.last_write_time # => a monotonic Time::Span just recorded
    # ```
    def last_write_time : Time::Span
      key = replica_tracker_key
      tracker = replica_lag_trackers[key] ||= ReplicaLagTracker.new(lag_threshold: replica_lag_threshold)
      tracker.last_write_time
    end

    # Records that a write just happened for the current database/shard,
    # resetting the post-write quiet period so subsequent reads stay on the
    # primary until enough time passes. Grant calls this automatically after
    # writes; call it yourself only when issuing raw writes Grant cannot see.
    #
    # ```
    # User.adapter.open { |db| db.exec("UPDATE users SET ...") }
    # User.mark_write_operation # tell the splitter a write happened
    # ```
    def mark_write_operation
      key = replica_tracker_key
      tracker = replica_lag_trackers[key] ||= ReplicaLagTracker.new(lag_threshold: replica_lag_threshold)
      tracker.mark_write
      replica_lag_trackers[key] = tracker
    end

    # Forces reads onto the primary for at least *duration* (default 5 seconds),
    # regardless of write timing — useful when you need guaranteed
    # read-your-writes consistency for a window after an out-of-band change.
    #
    # ```
    # User.stick_to_primary(10.seconds)
    # User.where(active: true).select # served by the primary for the next 10s
    # ```
    def stick_to_primary(duration : Time::Span = 5.seconds)
      key = replica_tracker_key
      tracker = replica_lag_trackers[key] ||= ReplicaLagTracker.new(lag_threshold: replica_lag_threshold)
      tracker.stick_to_primary(duration)
      replica_lag_trackers[key] = tracker
    end

    # Check if should use reader with enhanced logic
    private def should_use_reader? : Bool
      # Only use reader if:
      # 1. We have a reading role configured
      # 2. Enough time has passed since last write
      # 3. We're not explicitly using a different role
      # 4. Read replicas are healthy
      return false unless connection_config.has_key?(:reading)
      return false if connection_context.try(&.role)

      # Check replica health
      if lb = ConnectionRegistry.get_load_balancer(current_database, current_shard)
        return false unless lb.any_healthy?
      end

      # Check replica lag tracking
      key = replica_tracker_key
      tracker = replica_lag_trackers[key]? || ReplicaLagTracker.new(lag_threshold: replica_lag_threshold)

      # Convert connection_switch_wait_period (milliseconds) to Time::Span
      wait_period = connection_switch_wait_period.milliseconds
      tracker.can_use_replica?(wait_period)
    end

    # Get key for replica tracker
    private def replica_tracker_key : String
      if shard = current_shard
        "#{current_database}:#{shard}"
      else
        current_database
      end
    end
  end

  # Sets the model's default connection to the named database — the simplest
  # form of connection assignment, equivalent to `connects_to(database: name)`
  # with no role or shard configuration.
  #
  # *name* is given bare (an identifier or string literal) and stored as a
  # `String`. Prefer `#connects_to` for anything involving read/write splitting
  # or sharding; this legacy macro is retained for single-connection models.
  #
  # ```
  # class User < Grant::Base
  #   connection my_database # uses the "my_database" connection
  # end
  # ```
  macro connection(name)
    self.database_name = {{name.id.stringify}}
  end

  macro included
    extend ClassMethods
  end
end
