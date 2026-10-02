require "./connection_registry"
require "./connection_context"
require "./connection_handling"
require "./connection_pooling"

# Multi-database connection management, mixed into every `Grant::Base` model.
#
# Provides the DSL and runtime for: choosing a model's default connection
# (`connection` / `connects_to`), automatic read/write splitting across primary
# and replica connections, horizontal sharding, read-only windows, and the
# write-tracking that decides when a replica is safe to read. The public entry
# points are the `connects_to` / `connection` / `configure_connection` macros and
# the `ClassMethods` (`connected_to`, `while_preventing_writes`, `current_role`,
# `adapter`, etc.). Named connections themselves are established via
# `Grant::ConnectionRegistry.establish_connection`.
module Grant::ConnectionManagement
  # Whether any class's innermost context in this fiber prevents writes. Raw
  # connections that belong to no model (`Grant.connection`) use this, so a
  # write-preventing block on one model is not hidden by a later, unrelated
  # `connected_to` on another. An owner's own later context (for example an
  # explicit writing role) still lifts that owner's prevention.
  #
  # :nodoc:
  def self.preventing_writes? : Bool
    return false unless state = ConnectionState.current?

    contexts = state.contexts
    contexts.each_with_index do |context, index|
      next unless context.prevent_writes

      owner = context.owner
      superseded = (index + 1...contexts.size).any? { |later| contexts[later].owner == owner }
      return true unless superseded
    end
    false
  end

  # :nodoc:
  def self.guard_writes! : Nil
    return unless preventing_writes?

    raise Grant::Transaction::ReadOnlyError.new("Write query attempted while writes are prevented")
  end

  # Maps the legacy `:primary` role onto the configured writing role, so
  # `connects_to(config: {writing: ...})` also serves models that never named a
  # role.
  #
  # :nodoc:
  def self.canonical_role(role : Symbol) : Symbol
    role == :primary ? Grant.settings.writing_role : role
  end

  # :nodoc:
  def self.reading_role?(role : Symbol) : Bool
    canonical_role(role) == Grant.settings.reading_role
  end

  # :nodoc:
  def self.writing_role?(role : Symbol) : Bool
    canonical_role(role) == Grant.settings.writing_role
  end

  # Role name the connection registry knows a configured role by. The registry
  # always says `:reading` and `:writing`, whatever `Grant.settings` renames
  # them; `:primary` is the writing role, which the registry also serves from a
  # connection established without a role.
  #
  # :nodoc:
  def self.registry_role(role : Symbol) : Symbol
    settings = Grant.settings
    role = canonical_role(role)
    if role == settings.reading_role
      :reading
    elsif role == settings.writing_role
      :writing
    else
      role
    end
  end

  # Per database/shard bookkeeping for the read/write splitter: when the last
  # write happened, an optional "stick to primary until" deadline, and the lag
  # threshold. Drives the decision of whether a read may safely use a replica.
  class ReplicaLagTracker
    # Monotonic timestamp of the most recent tracked write.
    property last_write_time : Time::Instant
    # Monotonic deadline before which reads must use the primary, or `nil`.
    property sticky_until : Time::Instant?
    # Whether a write has been tracked since this tracker was created.
    property? written : Bool
    # How stale a replica may be before reads return to the primary.
    property lag_threshold : Time::Span

    def initialize(@last_write_time = Time.instant,
                   @sticky_until = nil,
                   @lag_threshold = 2.seconds,
                   @written = false)
    end

    # Records a write now, resetting `last_write_time` to the current monotonic
    # clock so the post-write quiet period starts over.
    #
    # ```
    # tracker.mark_write
    # ```
    def mark_write
      @last_write_time = Time.instant
      @written = true
    end

    # Forces reads onto the primary for the next *duration* by setting
    # `sticky_until` to now + *duration*.
    #
    # ```
    # tracker.stick_to_primary(5.seconds)
    # ```
    def stick_to_primary(duration : Time::Span)
      @sticky_until = Time.instant + duration
    end

    # Returns `true` when a replica may be read from: there is no active sticky
    # window AND at least *wait_period* has elapsed since the last write.
    #
    # ```
    # tracker.can_use_replica?(2.seconds) # => true once 2s have passed write-free
    # ```
    def can_use_replica?(wait_period : Time::Span) : Bool
      now = Time.instant

      # Check if we're in sticky period
      if sticky = @sticky_until
        return false if now < sticky
      end

      # Check if enough time has passed since last write
      !written? || now - @last_write_time > wait_period
    end
  end

  # Replica lag state for every model, keyed by model class name and
  # database/shard, so each model keeps the separate trackers it had when this
  # state was per class.
  #
  # It lives on this module, outside `macro included`, and is read only from
  # this module's own class methods. That makes it one set of class variables,
  # initialized when Grant loads. A class variable declared in `macro included`
  # is copied into every model class instead, and the compiler can leave a
  # model's copy without its initializer: when it first types the model while
  # typing an instance variable initializer such as `@pet = Pet.new` in an Amber
  # controller, the copy stays zeroed memory, so the first `save` locked a null
  # mutex and crashed.
  @@replica_lag_trackers = {} of {String, String} => ReplicaLagTracker
  @@replica_lag_thresholds = {} of String => Time::Span
  @@replica_lag_mutex = Mutex.new

  # Yields the tracker of *model_name* for the database/shard *key*, creating it
  # on first use. The tracker is used under the registry lock, because the
  # read/write splitter reads it on every query.
  #
  # :nodoc:
  def self.with_replica_lag_tracker(model_name : String, key : String, & : ReplicaLagTracker -> T) : T forall T
    @@replica_lag_mutex.synchronize do
      tracker_key = {model_name, key}
      tracker = @@replica_lag_trackers[tracker_key]? || begin
        threshold = @@replica_lag_thresholds[model_name]? || default_replica_lag_threshold
        @@replica_lag_trackers[tracker_key] = ReplicaLagTracker.new(lag_threshold: threshold)
      end
      yield tracker
    end
  end

  # The lag threshold a model uses until it sets its own.
  #
  # :nodoc:
  def self.default_replica_lag_threshold : Time::Span
    2.seconds
  end

  # :nodoc:
  def self.replica_lag_threshold(model_name : String) : Time::Span
    @@replica_lag_mutex.synchronize do
      @@replica_lag_thresholds[model_name]? || default_replica_lag_threshold
    end
  end

  # :nodoc:
  def self.store_replica_lag_threshold(model_name : String, threshold : Time::Span) : Time::Span
    @@replica_lag_mutex.synchronize do
      @@replica_lag_thresholds[model_name] = threshold
    end
  end

  macro included
    # Connection configuration. Each class keeps only the values declared on
    # itself and resolves the rest through its superclass at use time, so a
    # `connects_to` on an abstract parent reaches subclasses declared earlier
    # and later. Temporary selections live only in the current fiber's
    # `ConnectionState`.
    @@own_default_database_name : String? = nil
    @@own_connection_config : Hash(Symbol, String)? = nil
    @@own_shard_config : Hash(Symbol, Hash(Symbol, String))? = nil
    @@abstract_class : Bool = false

    def self.default_database_name : String
      @@own_default_database_name || "primary"
    end

    def self.default_database_name=(database : String)
      @@own_default_database_name = database
    end

    def self.connection_config : Hash(Symbol, String)
      @@own_connection_config || (@@own_connection_config = {} of Symbol => String)
    end

    def self.connection_config=(config : Hash(Symbol, String))
      @@own_connection_config = config
    end

    def self.shard_config : Hash(Symbol, Hash(Symbol, String))
      @@own_shard_config || (@@own_shard_config = {} of Symbol => Hash(Symbol, String))
    end

    def self.shard_config=(config : Hash(Symbol, Hash(Symbol, String)))
      @@own_shard_config = config
    end

    # Whether this class is an abstract connection holder: it declares
    # `connects_to` for its subclasses and is not backed by a table itself. Not
    # inherited.
    def self.abstract_class? : Bool
      @@abstract_class
    end

    def self.abstract_class=(value : Bool)
      @@abstract_class = value
    end

    # :nodoc:
    def self.__connection_owned_by?(owner : String) : Bool
      owner == "Grant::Base"
    end

    # Returns the active database for this fiber, falling back to the model's
    # configured default when no connected_to block is active.
    def self.database_name : String
      connection_context_database || default_database_name
    end

    # Sets the model's configured default database. connected_to never changes
    # this shared class-level value.
    def self.database_name=(database : String)
      self.default_database_name = database
    end

    # Returns the current fiber's innermost `ConnectionContext` that applies to
    # this class, or `nil` when no `#connected_to` block is active (the default
    # primary/writing context). Reads a fiber-local slot without taking a lock.
    #
    # ```
    # User.connection_context # => nil (outside any connected_to block)
    # ```
    def self.connection_context : ConnectionContext?
      return nil unless state = ConnectionState.current?

      state.contexts.reverse_each do |context|
        owner = context.owner
        return context if owner.nil? || __connection_owned_by?(owner)
      end
      nil
    end

    # The database named by the innermost applicable `#connected_to` context
    # that named one, or `nil`. A context entered without *database* (for
    # example `Grant::Base.connected_to(role: :reading)`) switches the role
    # only, so each model keeps its own database under it.
    #
    # :nodoc:
    def self.connection_context_database : String?
      return nil unless state = ConnectionState.current?

      state.contexts.reverse_each do |context|
        owner = context.owner
        next unless owner.nil? || __connection_owned_by?(owner)
        if database = context.database
          return database
        end
      end
      nil
    end

    # Sets (or with `nil`, clears) this class's own `ConnectionContext` in the
    # current fiber. Managed by `#connected_to` and `#connecting_to`; you rarely
    # call it directly. Passing `nil` removes the contexts this class created
    # at the current block level: contexts of enclosing `#connected_to` blocks
    # stay until those blocks end.
    def self.connection_context=(ctx : ConnectionContext?)
      if ctx.nil?
        return unless state = ConnectionState.current?
        state.remove_block_level_contexts(self.name)
      else
        state = ConnectionState.current
        state.remove_block_level_contexts(self.name)
        state.contexts << ConnectionContext.new(
          ctx.database, ctx.role, ctx.shard, ctx.prevent_writes, self.name)
      end
    end

    # Replica lag tracking per model and database/shard. The trackers and the
    # threshold live in `Grant::ConnectionManagement` itself, not in class
    # variables declared here: see `ConnectionManagement.with_replica_lag_tracker`.
    private def self.with_replica_lag_tracker(key : String, & : ReplicaLagTracker -> T) : T forall T
      Grant::ConnectionManagement.with_replica_lag_tracker(name, key) { |tracker| yield tracker }
    end

    # How stale a replica may be before reads return to the primary. Each model
    # class has its own value, `2.seconds` until set.
    def self.replica_lag_threshold : Time::Span
      Grant::ConnectionManagement.replica_lag_threshold(name)
    end

    def self.replica_lag_threshold=(threshold : Time::Span) : Time::Span
      Grant::ConnectionManagement.store_replica_lag_threshold(name, threshold)
    end

    # Values declared through the setters below. Only a declared value is
    # pushed to the connection registry, so the defaults never override what
    # `establish_connection` was given.
    @@declared_failover_retry_attempts : Int32? = nil
    @@declared_health_check_interval : Time::Span? = nil
    @@declared_load_balancing_strategy : Grant::LoadBalancingStrategy? = nil

    # How many times a refused connection, or a read that lost its connection,
    # is retried (after which the error is raised). Setting it applies to every
    # connection of the databases this class connects to.
    def self.failover_retry_attempts : Int32
      @@declared_failover_retry_attempts || 3
    end

    def self.failover_retry_attempts=(value : Int32) : Int32
      @@declared_failover_retry_attempts = value
      __apply_connection_options
      value
    end

    # How often the health monitors of the databases this class connects to
    # probe their connection. Setting it restarts their monitors.
    def self.health_check_interval : Time::Span
      @@declared_health_check_interval || 30.seconds
    end

    def self.health_check_interval=(value : Time::Span) : Time::Span
      @@declared_health_check_interval = value
      __apply_connection_options
      value
    end

    # How reads spread across this class's read replicas; `nil` until one is
    # chosen, in which case the registry's round-robin applies.
    def self.load_balancing_strategy : Grant::LoadBalancingStrategy?
      @@declared_load_balancing_strategy
    end

    def self.load_balancing_strategy=(strategy : Grant::LoadBalancingStrategy) : Grant::LoadBalancingStrategy
      @@declared_load_balancing_strategy = strategy
      __apply_connection_options
      strategy
    end

    # Pushes the declared connection options to every database this class
    # connects to. `connects_to` calls it again, since a class can declare its
    # options before it names its databases.
    #
    # :nodoc:
    def self.__apply_connection_options : Nil
      names = connection_names.map { |(database, _, _)| database }.uniq
      names.each do |database|
        Grant::ConnectionRegistry.configure_database(
          database,
          retry_attempts: @@declared_failover_retry_attempts,
          health_check_interval: @@declared_health_check_interval,
          load_balancing_strategy: @@declared_load_balancing_strategy
        )
      end
    end
  end

  # Declares which database(s), roles, and shards a model connects to.
  #
  # All arguments are optional:
  #
  # * *database* — the default connection name (a `String`), or a `NamedTuple`
  #   of `role => connection_name` such as
  #   `{writing: "primary", reading: "primary_replica"}`, which is the
  #   ActiveRecord form. The hash form enables automatic read/write splitting:
  #   reads route to the `:reading` connection once enough time has passed since
  #   the last write (see `#stick_to_primary`), and the `:writing` name becomes
  #   the default database.
  # * *config* — the same `NamedTuple` as a separate argument, kept for
  #   compatibility. Do not pass it together with a `NamedTuple` *database*.
  # * *shards* — a `NamedTuple` of `shard_name => {role => connection_name}` for
  #   horizontal sharding. Switch the active shard at runtime with
  #   `#connected_to(shard: ...)`.
  #
  # Declared names are checked while compiling: they must be non-empty literals.
  # Whether each name is an established connection is checked by
  # `.verify_connections!` (or `Grant::ConnectionHandling.verify_all!`), because
  # models load before an application establishes its connections.
  #
  # A class that declares nothing inherits its superclass's settings when they
  # are read, so `connects_to` on an abstract parent applies to every subclass.
  # A class that calls `connects_to` owns its whole declaration, as in
  # ActiveRecord: the roles and shards it does not name are not taken from the
  # superclass.
  #
  # The named connections themselves must be established separately with
  # `Grant::ConnectionRegistry.establish_connection`.
  #
  # ```
  # abstract class ApplicationRecord < Grant::Base
  #   abstract_class
  #   connects_to database: {writing: "primary", reading: "primary_replica"}
  # end
  #
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
    {% if database.is_a?(NamedTupleLiteral) %}
      {% raise "connects_to: pass roles either as `database: {writing:, reading:}` or as `config:`, not both" if config %}
      {% config = database %}
      {% database = config[:writing] || config[:primary] %}
    {% end %}

    {% if database %}
      {% raise "connects_to: database name must be a String or Symbol literal, got #{database}" unless database.is_a?(StringLiteral) || database.is_a?(SymbolLiteral) %}
      {% raise "connects_to: database name must not be empty" if database.id.stringify.empty? %}
      self.database_name = {{database.id.stringify}}
    {% end %}

    {% if config %}
      {% raise "connects_to: config must be a NamedTuple of role: \"connection\"" unless config.is_a?(NamedTupleLiteral) %}
      self.connection_config = {
        {% for role, db_name in config %}
          {% raise "connects_to: connection name for #{role} must be a String or Symbol literal, got #{db_name}" unless db_name.is_a?(StringLiteral) || db_name.is_a?(SymbolLiteral) %}
          {% raise "connects_to: connection name for #{role} must not be empty" if db_name.id.stringify.empty? %}
          {{role.id.symbolize}} => {{db_name.id.stringify}},
        {% end %}
      } of Symbol => String
    {% else %}
      # A class that calls connects_to owns its whole declaration: roles it
      # does not name are not taken from its superclass.
      self.connection_config = {} of Symbol => String
    {% end %}

    {% if shards %}
      {% raise "connects_to: shards must be a NamedTuple of shard: {role: \"connection\"}" unless shards.is_a?(NamedTupleLiteral) %}
      self.shard_config = {
        {% for shard_name, shard_settings in shards %}
          {% raise "connects_to: shard #{shard_name} must be a NamedTuple of role: \"connection\"" unless shard_settings.is_a?(NamedTupleLiteral) %}
          {{shard_name.id.symbolize}} => {
            {% for role, db_name in shard_settings %}
              {% raise "connects_to: shard #{shard_name} connection for #{role} must be a non-empty String or Symbol literal, got #{db_name}" if !(db_name.is_a?(StringLiteral) || db_name.is_a?(SymbolLiteral)) || db_name.id.stringify.empty? %}
              {{role.id.symbolize}} => {{db_name.id.stringify}},
            {% end %}
          } of Symbol => String,
        {% end %}
      } of Symbol => Hash(Symbol, String)
    {% else %}
      self.shard_config = {} of Symbol => Hash(Symbol, String)
    {% end %}

    Grant::ConnectionHandling.declare({{@type.name.stringify}}, -> { {{@type}}.connection_names })
    {{@type}}.__apply_connection_options
  end

  # Marks the class as an abstract connection holder (see `.abstract_class?`).
  #
  # ```
  # abstract class AnalyticsRecord < Grant::Base
  #   abstract_class
  #   connects_to database: {writing: "analytics", reading: "analytics_replica"}
  # end
  # ```
  macro abstract_class
    self.abstract_class = true
  end

  # Marks the class as the application's primary abstract class, usually
  # `ApplicationRecord`. It is an abstract class that
  # `Grant::ConnectionHandling.primary_abstract_class_name` reports.
  macro primary_abstract_class
    self.abstract_class = true
    Grant::ConnectionHandling.primary_abstract_class_name = {{@type.name.stringify}}
  end

  # Configures connection behavior on the model from keyword *options*.
  #
  # Recognized keys (each maps to the matching `class_property`):
  #
  # * `replica_lag_threshold : Time::Span` — how stale a replica may be before
  #   reads are forced back to the primary.
  # * `failover_retry_attempts : Int32` — how many times a refused connection,
  #   or a read that lost its connection, is retried before the error is raised.
  # * `health_check_interval : Time::Span` — how often health checks run.
  # * `connection_switch_wait_period` — quiet period after a write before reads
  #   may use a replica.
  # * `load_balancing_strategy` — a `Grant::LoadBalancingStrategy`
  #   (`RoundRobinStrategy`, `RandomStrategy`, `LeastConnectionsStrategy`,
  #   `WeightedStrategy`) choosing among read replicas.
  #
  # Any other key is a compile-time error.
  #
  # ```
  # class User < Grant::Base
  #   configure_connection(
  #     replica_lag_threshold: 2.seconds,
  #     failover_retry_attempts: 3
  #   )
  # end
  # ```
  macro configure_connection(**options)
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
    def guard_writes! : Nil
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

    # Keeps calls to the former `connection_config(**options)` method working
    # while applications transition to `configure_connection(**options)`.
    @[Deprecated("Use configure_connection instead")]
    def connection_config(**options) : Nil
      options.each do |key, value|
        case key
        when :replica_lag_threshold
          self.replica_lag_threshold = value.as?(Time::Span) || raise ArgumentError.new("replica_lag_threshold must be a Time::Span")
        when :failover_retry_attempts
          self.failover_retry_attempts = value.as?(Int32) || raise ArgumentError.new("failover_retry_attempts must be an Int32")
        when :health_check_interval
          self.health_check_interval = value.as?(Time::Span) || raise ArgumentError.new("health_check_interval must be a Time::Span")
        when :connection_switch_wait_period
          self.connection_switch_wait_period = value.as?(Int32) || raise ArgumentError.new("connection_switch_wait_period must be an Int32")
        else
          raise ArgumentError.new("Unknown connection config option: #{key}")
        end
      end
    end

    # Runs the block with a temporary connection context — switching the
    # *database*, *role*, *shard*, and/or write-prevention — and restores the
    # previous context afterward (even on exception). Returns the block's value.
    #
    # Each argument defaults to `nil`/`false`, meaning "keep the current value".
    # The context is fiber-local, so concurrent fibers do not interfere, and it
    # applies to this class and its subclasses. This is the primary way to
    # target a replica, a specific shard, or a read-only window for a unit of
    # work.
    #
    # Switching to the reading role (`Grant.settings.reading_role`, `:reading`
    # by default) prevents writes, as in ActiveRecord: a write in the block
    # raises `Grant::Transaction::ReadOnlyError`. Passing an explicit writing
    # role inside such a block allows writes again. `:primary` is an alias of
    # the writing role.
    #
    # Passing *shard* raises `Grant::ShardSwappingProhibited` while
    # `#prohibit_shard_swapping` is active. A `Grant::Sharding::Model` class
    # routes to the block's shard when the block applies to it (the class or
    # an ancestor entered it) and no `Grant::ShardManager.with_shard` is active.
    #
    # ```
    # # force reads through the replica for this block (writes raise)
    # users = User.connected_to(role: :reading) { User.where(active: true).select }
    #
    # # target a specific shard
    # User.connected_to(shard: :shard_two) { User.find(id) }
    #
    # # read-only window on the writer
    # User.connected_to(prevent_writes: true) { report.run }
    # ```
    def connected_to(
      database : String? = nil,
      role : Symbol? = nil,
      shard : Symbol? = nil,
      prevent_writes : Bool = false,
      &block : -> T
    ) : T forall T
      context = build_connection_context(database, role, shard, prevent_writes)
      state = ConnectionState.current
      depth = state.contexts.size
      state.contexts << context
      outer_floor = state.block_floor
      state.block_floor = depth + 1

      begin
        yield
      ensure
        # Restore the stack to its depth on entry rather than popping one entry,
        # so a `connecting_to` made inside the block ends with it. Contexts
        # below the floor are never removed while the block runs, so this
        # removes exactly the block's own entries.
        contexts = state.contexts
        contexts.pop(contexts.size - depth) if contexts.size > depth
        state.block_floor = outer_floor
      end
    end

    # `connected_to` with a role hash, as ActiveRecord's
    # `connected_to(database: {reading: :replica})`: *database* maps a role to
    # the connection to use. The role is *role*, or the hash's only key. The
    # block then runs with that role and connection.
    #
    # ```
    # User.connected_to(database: {reading: "primary_replica"}) { User.count }
    # ```
    def connected_to(
      *,
      database : NamedTuple,
      role : Symbol? = nil,
      shard : Symbol? = nil,
      prevent_writes : Bool = false,
      &block : -> T
    ) : T forall T
      roles = {} of Symbol => String
      database.each { |key, name| roles[key] = name.to_s }
      connected_to(database: roles, role: role, shard: shard, prevent_writes: prevent_writes) { yield }
    end

    # :ditto:
    def connected_to(
      *,
      database : Hash(Symbol, String),
      role : Symbol? = nil,
      shard : Symbol? = nil,
      prevent_writes : Bool = false,
      &block : -> T
    ) : T forall T
      chosen = role || (database.size == 1 ? database.first_key : nil)
      unless chosen
        raise ArgumentError.new("connected_to(database: {...}) with #{database.size} roles needs role: to pick one of #{database.keys.join(", ")}")
      end
      name = database[chosen]? || raise ArgumentError.new(
        "connected_to(database:) has no connection for role #{chosen.inspect}; it names #{database.keys.join(", ")}")
      connected_to(database: name, role: chosen, shard: shard, prevent_writes: prevent_writes) { yield }
    end

    # Switches this fiber to the given *role*, *shard*, and/or *database*
    # without a block; the switch lasts until `#reset_connecting_to` or the end
    # of the fiber. The rules of `#connected_to` apply, including write
    # prevention for the reading role.
    #
    # ```
    # User.connecting_to(role: :reading)
    # User.connected_to?(role: :reading) # => true
    # User.reset_connecting_to
    # ```
    def connecting_to(
      database : String? = nil,
      role : Symbol? = nil,
      shard : Symbol? = nil,
      prevent_writes : Bool = false,
    ) : Nil
      context = build_connection_context(database, role, shard, prevent_writes)
      ConnectionState.current.contexts << context
      nil
    end

    # Removes every context `#connecting_to` or `#connected_to` created for this
    # class in the current fiber.
    def reset_connecting_to : Nil
      self.connection_context = nil
    end

    # Returns `true` when the connection in effect has the given *role* and/or
    # *shard*. Roles are compared after aliasing `:primary` to the writing role.
    # An unsharded connection counts as `default_shard`.
    #
    # ```
    # User.connected_to?(role: :reading)                                       # => false
    # User.connected_to(role: :reading) { User.connected_to?(role: :reading) } # => true
    # ```
    def connected_to?(role : Symbol? = nil, shard : Symbol? = nil) : Bool
      raise ArgumentError.new("connected_to? needs a role or a shard") if role.nil? && shard.nil?

      if role
        return false unless Grant::ConnectionManagement.canonical_role(current_role) == Grant::ConnectionManagement.canonical_role(role)
      end
      if shard
        return false unless (current_shard || default_shard) == shard
      end
      true
    end

    # Runs the block while `connected_to(shard: ...)` raises
    # `Grant::ShardSwappingProhibited`, so nested code cannot leave the shard a
    # request is pinned to. The flag is fiber-local and restored afterward;
    # passing `false` lifts it for the block.
    #
    # ```
    # User.connected_to(shard: :tenant_a) do
    #   User.prohibit_shard_swapping do
    #     User.connected_to(shard: :tenant_b) { } # raises
    #   end
    # end
    # ```
    def prohibit_shard_swapping(enabled : Bool = true, &block : -> T) : T forall T
      state = ConnectionState.current
      previous = state.shard_swapping_prohibited?
      state.shard_swapping_prohibited = enabled
      begin
        yield
      ensure
        state.shard_swapping_prohibited = previous
      end
    end

    # Returns `true` while `#prohibit_shard_swapping` is active in this fiber.
    def shard_swapping_prohibited? : Bool
      return false unless state = ConnectionState.current?

      state.shard_swapping_prohibited?
    end

    # Shard names declared with `connects_to(shards: ...)`, in declaration order.
    def shard_keys : Array(Symbol)
      shard_config.keys
    end

    # The shard an unsharded connection counts as: `:default` when declared,
    # otherwise the first declared shard, otherwise `:default`.
    def default_shard : Symbol
      return :default if shard_config.has_key?(:default)

      shard_config.first_key? || :default
    end

    # Returns `true` when `connects_to(shards: ...)` declared any shard.
    def sharded? : Bool
      !shard_config.empty?
    end

    # Every connection name this class's `connects_to` reaches, with the role
    # and shard each one serves.
    def connection_names : Array({String, Symbol, Symbol?})
      names = [] of {String, Symbol, Symbol?}
      if connection_config.empty? && shard_config.empty?
        names << {default_database_name, :writing, nil}
      end
      connection_config.each { |role, name| names << {name, role, nil} }
      shard_config.each do |shard, roles|
        roles.each { |role, name| names << {name, role, shard} }
      end
      names.uniq
    end

    # Raises `Grant::UnestablishedConnectionError` when a connection this class
    # declares is not established; call it at boot to fail early rather than at
    # the first query. See `Grant::ConnectionHandling.verify!`.
    def verify_connections! : Nil
      Grant::ConnectionHandling.verify!(name, connection_names)
    end

    private def build_connection_context(
      database : String?,
      role : Symbol?,
      shard : Symbol?,
      prevent_writes : Bool,
    ) : ConnectionContext
      if shard && shard_swapping_prohibited?
        raise Grant::ShardSwappingProhibited.new(
          "Cannot switch to shard #{shard.inspect} for #{name} while shard swapping is prohibited")
      end

      previous = connection_context
      inherited_prevention = previous ? previous.prevent_writes : false
      # An explicit writing role lifts prevention that only came from a reading role.
      if inherited_prevention && role && previous && Grant::ConnectionManagement.writing_role?(role) && Grant::ConnectionManagement.reading_role?(previous.role)
        inherited_prevention = false
      end
      implied = role ? Grant::ConnectionManagement.reading_role?(role) : false

      ConnectionContext.new(
        database,
        role || current_role,
        shard || current_shard,
        prevent_writes || implied || inherited_prevention,
        name
      )
    end

    # Returns the name (`String`) of the database the model is currently using —
    # the active `#connected_to` context's database if one is set, otherwise the
    # model's configured `default_database_name`.
    #
    # ```
    # User.current_database                                              # => "primary"
    # User.connected_to(database: "analytics") { User.current_database } # => "analytics"
    # ```
    def current_database : String
      connection_context_database || default_database_name
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
      return Grant.settings.reading_role if should_use_reader?
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
    def while_preventing_writes(&block : -> T) : T forall T
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
      resolve_adapter_for_role(current_role)
    end

    # The adapter serving *shard* in *role*, whatever shard is active: the
    # connection `connects_to(shards: ...)` names for that shard and role, else
    # the model's own database registered under that shard. `Sharding::Model`
    # resolves its shard from the data and calls this. It never falls back to
    # another registered connection.
    def adapter_for_shard(shard : Symbol, role : Symbol = current_role) : Grant::Adapter::Base
      resolve_adapter_for_role(role, shard, fallback: false)
    end

    # Resolves a model's connection for an explicit raw-SQL operation role.
    # An active `connected_to` role takes precedence, matching the surrounding
    # connection context; otherwise *role* selects the model's configured
    # writer or reader.
    def connection_adapter(role : Symbol) : Grant::Adapter::Base
      resolve_adapter_for_role(connection_context.try(&.role) || role)
    end

    private def resolve_adapter_for_role(role : Symbol, shard : Symbol? = current_shard, fallback : Bool = true) : Grant::Adapter::Base
      registry_role = Grant::ConnectionManagement.registry_role(role)
      configured_role = Grant::ConnectionManagement.canonical_role(role)

      # The `:default` shard is the unsharded connection, so it carries no
      # shard key in the registry.
      shard = nil if shard == :default && shard_config.has_key?(:default)

      # Determine database name
      db_name = if shard
                  # For sharded connections, look up the database name
                  shard_settings = shard_config[shard]?
                  shard_settings.try(&.[configured_role]?) || current_database
                elsif ctx_db = connection_context_database
                  # An explicit `connected_to(database:)` names the connection.
                  ctx_db
                elsif role_db = connection_config[configured_role]? || connection_config[role]?
                  # For role-based connections; `:primary` is the writing role
                  role_db
                elsif default_settings = shard_config[:default]?
                  # No role-based declaration: the `:default` shard serves the
                  # unsharded connection.
                  default_settings[configured_role]? || default_settings[:writing]? || current_database
                else
                  # Default database
                  current_database
                end

      # A connection that `connects_to(shards:)` names for this shard is
      # registered under its own name; one registered with the shard key is
      # found by it.
      if shard && shard_config[shard]?.try(&.has_key?(configured_role)) && !registered_for_shard?(db_name, registry_role, shard)
        shard = nil
      end

      begin
        ConnectionRegistry.get_adapter(db_name, registry_role, shard)
      rescue ex : Grant::AdapterNotAvailableError
        # A sharded model never borrows another connection: that would send a
        # shard's rows to the wrong database.
        raise ex unless fallback

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

    private def registered_for_shard?(database : String, registry_role : Symbol, shard : Symbol) : Bool
      registry = Grant::ConnectionRegistry
      registry.connection_exists?(database, registry_role, shard) ||
        registry.connection_exists?(database, :primary, shard) ||
        (registry_role == :reading && registry.connection_exists?(database, :writing, shard))
    end

    # Returns a raw connection facade for this model. Connection calls do not
    # apply `default_scope`; model-level raw methods enforce the explicit
    # `unscoped` rule before using this facade.
    def connection : Grant::Connection
      Grant::Connection.new(
        ->(role : Symbol) do
          Grant::ConnectionManagement.writing_role?(role) ? connection_adapter(Grant.settings.writing_role) : adapter
        end,
        -> do
          guard_writes!
          mark_write_operation
          nil
        end
      )
    end

    # Returns the monotonic `Time::Instant` timestamp of the most recent write
    # tracked for the current database/shard. Used by the read/write splitter to
    # decide when a replica is safe to read from after a write.
    #
    # ```
    # User.create(name: "Ada")
    # User.last_write_time # => a monotonic Time::Instant just recorded
    # ```
    def last_write_time : Time::Instant
      key = replica_tracker_key
      with_replica_lag_tracker(key, &.last_write_time)
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
    def mark_write_operation : Nil
      key = replica_tracker_key
      with_replica_lag_tracker(key, &.mark_write)
    end

    # Forces reads onto the primary for at least *duration* (default 5 seconds),
    # regardless of write timing — useful when you need guaranteed
    # read-your-writes consistency for a window after an out-of-band change.
    #
    # ```
    # User.stick_to_primary(10.seconds)
    # User.where(active: true).select # served by the primary for the next 10s
    # ```
    def stick_to_primary(duration : Time::Span = 5.seconds) : Nil
      key = replica_tracker_key
      with_replica_lag_tracker(key) { |tracker| tracker.stick_to_primary(duration) }
    end

    # Check if should use reader with enhanced logic
    private def should_use_reader? : Bool
      # Only use reader if:
      # 1. We have a reading role configured
      # 2. Enough time has passed since last write
      # 3. We're not explicitly using a different role
      # 4. Read replicas are healthy
      return false unless connection_config.has_key?(Grant.settings.reading_role)
      return false if connection_context.try(&.role)
      # Every statement inside an open transaction must reach the transaction's
      # writer connection; a replica read would miss its uncommitted rows and a
      # write would escape the transaction entirely.
      return false if Grant::Transaction.in_explicit_transaction?

      # Check replica health
      if lb = ConnectionRegistry.get_load_balancer(current_database, current_shard)
        return false unless lb.any_healthy?
      end

      # Check replica lag tracking
      key = replica_tracker_key
      # Convert connection_switch_wait_period (milliseconds) to Time::Span
      wait_period = connection_switch_wait_period.milliseconds
      with_replica_lag_tracker(key) { |tracker| tracker.can_use_replica?(wait_period) }
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
    extend PoolClassMethods
  end
end
