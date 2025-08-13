require "./connection_registry"

# Connection management is now built into Grant::Base
# This provides multiple database support, sharding, and role-based connections
module Grant::ConnectionManagement
  # Connection context for tracking current database/role/shard
  struct ConnectionContext
    property database : String
    property role : Symbol
    property shard : Symbol?
    property prevent_writes : Bool
    
    def initialize(@database, @role = :primary, @shard = nil, @prevent_writes = false)
    end
  end
  
  # Replica lag tracking per database/shard
  struct ReplicaLagTracker
    property last_write_time : Time::Span
    property sticky_until : Time::Span?
    property lag_threshold : Time::Span
    
    def initialize(@last_write_time = Time.monotonic, 
                   @sticky_until = nil,
                   @lag_threshold = 2.seconds)
    end
    
    def mark_write
      @last_write_time = Time.monotonic
    end
    
    def stick_to_primary(duration : Time::Span)
      @sticky_until = Time.monotonic + duration
    end
    
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
    
    # Thread-local connection context
    class_property connection_context : ConnectionContext?
    
    # Enhanced replica lag tracking per database/shard
    class_property replica_lag_trackers = {} of String => ReplicaLagTracker
    
    # Connection behavior configuration
    class_property replica_lag_threshold : Time::Span = 2.seconds
    class_property failover_retry_attempts : Int32 = 3
    class_property health_check_interval : Time::Span = 30.seconds
  end
  
  # DSL for configuring connections
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
  
  # DSL macro for configuring connection behavior
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
    # Delegate connection_switch_wait_period to Grant::Connections for backward compatibility
    def connection_switch_wait_period
      Grant::Connections.connection_switch_wait_period
    end
    
    def connection_switch_wait_period=(value : Int32)
      Grant::Connections.connection_switch_wait_period = value
    end
    
    # Switch connection for a block
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
    
    # Get current database
    def current_database : String
      connection_context.try(&.database) || database_name
    end
    
    # Get current role
    def current_role : Symbol
      return :reading if should_use_reader?
      connection_context.try(&.role) || :primary
    end
    
    # Get current shard
    def current_shard : Symbol?
      connection_context.try(&.shard)
    end
    
    # Check if currently preventing writes
    def preventing_writes? : Bool
      connection_context.try(&.prevent_writes) || false
    end
    
    # Block writes for a block
    def while_preventing_writes(&)
      connected_to(prevent_writes: true) do
        yield
      end
    end
    
    # Get the current adapter
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
      rescue
        # Fallback to first registered connection for backward compatibility
        # This handles cases where models haven't configured connections yet
        if reg = Grant::Connections.registered_connections
          if conn = reg.first?
            conn[:writer]
          else
            raise "No database connection configured. Please use Grant::ConnectionRegistry.establish_connection"
          end
        else
          raise "No database connection configured. Please use Grant::ConnectionRegistry.establish_connection"
        end
      end
    end
    
    # Mark write operation with enhanced tracking
    def mark_write_operation
      key = replica_tracker_key
      tracker = replica_lag_trackers[key] ||= ReplicaLagTracker.new(lag_threshold: replica_lag_threshold)
      tracker.mark_write
      replica_lag_trackers[key] = tracker
    end
    
    # Stick to primary for a duration
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
  
  # Legacy support - will be removed
  macro connection(name)
    self.database_name = {{name.id.stringify}}
  end
  
  macro included
    extend ClassMethods
  end
end
