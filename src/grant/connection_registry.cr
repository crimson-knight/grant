require "./health_monitor"
require "./replica_load_balancer"

module Grant
  # Central registry for managing database connections
  class ConnectionRegistry
    # Connection specification with pool configuration
    struct ConnectionSpec
      property database : String
      property adapter_class : Grant::Adapter::Base.class
      property url : String
      property role : Symbol
      property shard : Symbol?
      
      # Pool configuration
      property pool_size : Int32 = 25
      property initial_pool_size : Int32 = 2
      property checkout_timeout : Time::Span = 5.seconds
      property retry_attempts : Int32 = 1
      property retry_delay : Time::Span = 0.2.seconds
      
      # Health check configuration
      property health_check_interval : Time::Span = 30.seconds
      property health_check_timeout : Time::Span = 5.seconds
      
      def initialize(@database, @adapter_class, @url, @role, @shard = nil,
                     @pool_size = 25, @initial_pool_size = 2,
                     @checkout_timeout = 5.seconds, @retry_attempts = 1,
                     @retry_delay = 0.2.seconds, @health_check_interval = 30.seconds,
                     @health_check_timeout = 5.seconds)
      end
      
      def connection_key : String
        if shard
          "#{database}:#{role}:#{shard}"
        else
          "#{database}:#{role}"
        end
      end
      
      # Build URL with pool parameters for crystal-db
      def build_pool_url : String
        uri = URI.parse(@url)
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
    
    # Establish a new connection with pool configuration
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
      health_check_timeout : Time::Span = 5.seconds
    )
      spec = ConnectionSpec.new(
        database, adapter, url, role, shard,
        pool_size, initial_pool_size, checkout_timeout,
        retry_attempts, retry_delay, health_check_interval,
        health_check_timeout
      )
      key = spec.connection_key
      
      @@mutex.synchronize do
        # Store specification
        @@specifications[key] = spec
        
        # Create adapter instance with pooled URL
        adapter_instance = adapter.new(key, spec.build_pool_url)
        @@adapters[key] = adapter_instance
        
        # Create and register health monitor (unless in test mode)
        unless HealthMonitor.test_mode
          HealthMonitorRegistry.register(key, adapter_instance, spec)
        end
        
        # Track read replicas for load balancing
        if role == :reading
          lb_key = shard ? "#{database}:#{shard}" : database
          
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
        
        # TODO: Register with the old system for backward compatibility
        # Temporarily disabled due to conflicts in tests
        
        # Set as default if first database
        @@default_database ||= database
        
        # Connection established successfully
      end
    end
    
    # Register multiple connections at once
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
      end
    end
    
    # Get an adapter with load balancing and failover support
    def self.get_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Grant::Adapter::Base
      key = if shard
        "#{database}:#{role}:#{shard}"
      else
        "#{database}:#{role}"
      end
      
      @@mutex.synchronize do
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
        
        adapter || raise "No adapter found for #{key}"
      end
    end
    
    # Try to find a fallback adapter
    private def self.try_fallback_adapter(database : String, role : Symbol, shard : Symbol?) : Grant::Adapter::Base?
      # Fallback to primary role if specific role not found
      if role != :primary
        key = shard ? "#{database}:primary:#{shard}" : "#{database}:primary"
        if adapter = @@adapters[key]?
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
        if adapter = @@adapters[key]?
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
    
    # Execute with a specific adapter
    def self.with_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil, &)
      adapter = get_adapter(database, role, shard)
      yield adapter
    end
    
    # Get all adapters for a database
    def self.adapters_for_database(database : String) : Array(Grant::Adapter::Base)
      @@mutex.synchronize do
        @@adapters.select { |key, _| key.starts_with?("#{database}:") }.values
      end
    end
    
    # Get adapter names
    def self.adapter_names : Array(String)
      @@mutex.synchronize do
        @@adapters.keys
      end
    end
    
    # Clear all adapters
    def self.clear_all
      @@mutex.synchronize do
        @@adapters.clear
        @@specifications.clear
        @@default_database = nil
      end
      
      # All adapters cleared
    end
    
    # Get default database name
    def self.default_database : String
      @@default_database || raise "No default database configured"
    end
    
    # Set default database
    def self.default_database=(name : String)
      @@default_database = name
    end
    
    # Check if a connection exists
    def self.connection_exists?(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Bool
      key = shard ? "#{database}:#{role}:#{shard}" : "#{database}:#{role}"
      @@mutex.synchronize { @@adapters.has_key?(key) }
    end
    
    # Get all registered databases
    def self.databases : Array(String)
      @@mutex.synchronize do
        @@specifications.values.map(&.database).uniq
      end
    end
    
    # Get all shards for a database
    def self.shards_for_database(database : String) : Array(Symbol)
      @@mutex.synchronize do
        @@specifications.values
          .select { |spec| spec.database == database && spec.shard }
          .map(&.shard.not_nil!)
          .uniq
      end
    end
    
    # Pool configuration is now handled by crystal-db URL parameters
    
    # Get health status for all connections
    def self.health_status : Array(NamedTuple(key: String, healthy: Bool, database: String, role: Symbol))
      @@mutex.synchronize do
        @@specifications.map do |key, spec|
          monitor = HealthMonitorRegistry.get(key)
          {
            key: key,
            healthy: monitor.nil? || monitor.healthy?,
            database: spec.database,
            role: spec.role
          }
        end
      end
    end
    
    # Get load balancer for a database/shard
    def self.get_load_balancer(database : String, shard : Symbol? = nil) : ReplicaLoadBalancer?
      lb_key = shard ? "#{database}:#{shard}" : database
      @@mutex.synchronize { @@load_balancers[lb_key]? }
    end
    
    # Check overall system health
    def self.system_healthy? : Bool
      HealthMonitorRegistry.all_healthy?
    end
    
    # Clear all resources
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