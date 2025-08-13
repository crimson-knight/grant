# Advanced Multi-Database Support Design

## Overview

This document outlines the design for enhancing Grant's multi-database support with production-ready features including connection pooling, read/write splitting, replica lag handling, health checks, automatic failover, and load balancing.

## Current State Analysis

### What Exists
- `ConnectionRegistry` - manages database connections and specifications
- `ConnectionManagement` - provides DSL for models to specify connections
- Basic role support (reading/writing/primary)
- Basic shard support
- Connection switching via `connected_to` blocks

### What's Missing
1. **Connection Pooling Configuration** - crystal-db provides pooling but we need to expose configuration
2. **Health Checks** - no monitoring of connection health
3. **Automatic Failover** - no fallback when connections fail
4. **Load Balancing** - no distribution across multiple replicas
5. **Replica Lag Handling** - basic time-based switching exists but needs enhancement

## Proposed Architecture

### 1. Enhanced Connection Specification

```crystal
module Grant
  struct ConnectionSpec
    property database : String
    property adapter_class : Adapter::Base.class
    property url : String
    property role : Symbol
    property shard : Symbol?
    
    # New pool configuration
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
  end
end
```

### 2. Connection Pool Management

```crystal
module Grant
  class PooledAdapter < Adapter::Base
    @pool : DB::Database
    @health_monitor : HealthMonitor
    
    def initialize(name : String, url : String, config : ConnectionSpec)
      super(name, url)
      
      # Configure crystal-db pool with URL parameters
      pool_url = build_pool_url(url, config)
      @pool = DB.open(pool_url)
      
      # Start health monitoring
      @health_monitor = HealthMonitor.new(self, config)
      @health_monitor.start
    end
    
    private def build_pool_url(base_url : String, config : ConnectionSpec) : String
      uri = URI.parse(base_url)
      params = uri.query_params
      
      params["max_pool_size"] = config.pool_size.to_s
      params["initial_pool_size"] = config.initial_pool_size.to_s
      params["checkout_timeout"] = config.checkout_timeout.total_seconds.to_s
      params["retry_attempts"] = config.retry_attempts.to_s
      params["retry_delay"] = config.retry_delay.total_seconds.to_s
      
      uri.query = params.to_s
      uri.to_s
    end
    
    def healthy? : Bool
      @health_monitor.healthy?
    end
    
    def database : DB::Database
      @pool
    end
  end
end
```

### 3. Health Monitoring

```crystal
module Grant
  class HealthMonitor
    @adapter : Adapter::Base
    @config : ConnectionSpec
    @healthy : Atomic(Bool) = Atomic(Bool).new(true)
    @last_check : Time = Time.utc
    @check_fiber : Fiber?
    
    def initialize(@adapter, @config)
    end
    
    def start
      @check_fiber = spawn do
        loop do
          sleep @config.health_check_interval
          check_health
        end
      end
    end
    
    def healthy? : Bool
      @healthy.get
    end
    
    private def check_health
      begin
        # Perform health check with timeout
        channel = Channel(Bool).new
        
        spawn do
          begin
            @adapter.open do |db|
              db.scalar("SELECT 1")
            end
            channel.send(true)
          rescue
            channel.send(false)
          end
        end
        
        select
        when result = channel.receive
          @healthy.set(result)
          @last_check = Time.utc
        when timeout(@config.health_check_timeout)
          @healthy.set(false)
          Log.warn { "Health check timeout for #{@adapter.name}" }
        end
      rescue ex
        @healthy.set(false)
        Log.error { "Health check failed for #{@adapter.name}: #{ex.message}" }
      end
    end
  end
end
```

### 4. Load Balancer for Replicas

```crystal
module Grant
  class ReplicaLoadBalancer
    @replicas : Array(Adapter::Base)
    @current_index : Atomic(Int32) = Atomic(Int32).new(0)
    
    def initialize(@replicas : Array(Adapter::Base))
    end
    
    # Round-robin selection with health awareness
    def next_replica : Adapter::Base?
      return nil if @replicas.empty?
      
      start_index = @current_index.get
      attempts = 0
      
      loop do
        index = @current_index.add(1) % @replicas.size
        replica = @replicas[index]
        
        if replica.healthy?
          return replica
        end
        
        attempts += 1
        if attempts >= @replicas.size
          # All replicas unhealthy, return least recently failed
          return @replicas.min_by { |r| r.last_health_check_time }
        end
      end
    end
    
    def healthy_replicas : Array(Adapter::Base)
      @replicas.select(&.healthy?)
    end
    
    def all_healthy? : Bool
      @replicas.all?(&.healthy?)
    end
  end
end
```

### 5. Enhanced Connection Registry

```crystal
module Grant
  class ConnectionRegistry
    # Add replica tracking
    @@replica_groups = {} of String => ReplicaLoadBalancer
    
    # Enhanced connection establishment
    def self.establish_connection(
      database : String,
      adapter : Adapter::Base.class,
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
        @@specifications[key] = spec
        
        # Create pooled adapter
        adapter_instance = PooledAdapter.new(key, url, spec)
        @@adapters[key] = adapter_instance
        
        # Track replicas for load balancing
        if role == :reading
          replica_key = shard ? "#{database}:#{shard}" : database
          @@replica_groups[replica_key] ||= ReplicaLoadBalancer.new([] of Adapter::Base)
          @@replica_groups[replica_key].add_replica(adapter_instance)
        end
        
        @@default_database ||= database
      end
    end
    
    # Get adapter with failover support
    def self.get_adapter(database : String, role : Symbol = :primary, shard : Symbol? = nil) : Adapter::Base
      key = build_key(database, role, shard)
      
      @@mutex.synchronize do
        adapter = @@adapters[key]?
        
        # For reading role, use load balancer
        if role == :reading && (lb = get_load_balancer(database, shard))
          if replica = lb.next_replica
            return replica
          end
        end
        
        # Fallback logic
        adapter ||= fallback_adapter(database, role, shard)
        adapter || raise "No adapter found for #{key}"
      end
    end
    
    private def self.get_load_balancer(database : String, shard : Symbol?) : ReplicaLoadBalancer?
      replica_key = shard ? "#{database}:#{shard}" : database
      @@replica_groups[replica_key]?
    end
    
    private def self.fallback_adapter(database : String, role : Symbol, shard : Symbol?) : Adapter::Base?
      # Try primary if specific role not found
      if role != :primary
        key = build_key(database, :primary, shard)
        return @@adapters[key]? if @@adapters.has_key?(key)
      end
      
      # Try writing if reading not available
      if role == :reading
        key = build_key(database, :writing, shard)
        return @@adapters[key]? if @@adapters.has_key?(key)
      end
      
      nil
    end
  end
end
```

### 6. Replica Lag Handling

```crystal
module Grant::ConnectionManagement
  # Enhanced lag tracking per connection
  class_property write_timestamps = {} of String => Time::Span
  
  module ClassMethods
    # Enhanced write tracking with connection awareness
    def mark_write_operation
      key = "#{current_database}:#{current_shard}"
      self.write_timestamps[key] = Time.monotonic
    end
    
    # Smarter replica usage decision
    private def should_use_reader? : Bool
      return false unless connection_config.has_key?(:reading)
      return false if connection_context.try(&.role)
      
      # Check write timestamp for current database/shard
      key = "#{current_database}:#{current_shard}"
      last_write = write_timestamps[key]? || Time.monotonic - 1.hour
      
      wait_period = connection_switch_wait_period.milliseconds
      
      # Also consider replica health
      if replica_lb = ConnectionRegistry.get_load_balancer(current_database, current_shard)
        return false unless replica_lb.any_healthy?
      end
      
      Time.monotonic - last_write > wait_period
    end
    
    # Sticky session support
    def with_primary_sticky(duration : Time::Span = 5.seconds, &)
      key = "#{current_database}:#{current_shard}"
      self.write_timestamps[key] = Time.monotonic + duration
      
      connected_to(role: :writing) do
        yield
      end
    ensure
      # Reset to actual write time
      self.write_timestamps[key] = Time.monotonic
    end
  end
end
```

### 7. Configuration DSL Enhancement

```crystal
# Allow models to configure connection behavior
class User < Grant::Base
  connects_to database: {
    writing: :primary,
    reading: :primary_replica
  }
  
  # New configuration options
  connection_config(
    replica_lag_threshold: 2.seconds,
    failover_retry_attempts: 3,
    health_check_interval: 60.seconds
  )
end
```

## Implementation Plan

### Phase 1: Connection Pooling (Week 1)
1. Implement PooledAdapter with crystal-db URL configuration
2. Update ConnectionRegistry to use PooledAdapter
3. Add pool monitoring and metrics
4. Write tests for pool configuration

### Phase 2: Health Monitoring (Week 2)
1. Implement HealthMonitor class
2. Add health check configuration to ConnectionSpec
3. Integrate health checks with adapters
4. Add health status reporting

### Phase 3: Load Balancing (Week 3)
1. Implement ReplicaLoadBalancer
2. Update ConnectionRegistry to track replica groups
3. Integrate load balancing with get_adapter
4. Add load balancing strategies (round-robin, least-connections)

### Phase 4: Failover & Recovery (Week 4)
1. Implement automatic failover logic
2. Add circuit breaker pattern
3. Implement recovery detection
4. Add failover event notifications

### Phase 5: Testing & Documentation (Week 5)
1. Comprehensive test suite
2. Performance benchmarks
3. Documentation and examples
4. Migration guide from current implementation

## Benefits

1. **Production Ready** - Health checks, failover, and monitoring
2. **Performance** - Connection pooling and load balancing
3. **Reliability** - Automatic failover and recovery
4. **Flexibility** - Configurable per model or globally
5. **Observability** - Health metrics and connection stats

## Backward Compatibility

All changes will be backward compatible:
- Existing connection configurations continue to work
- New features are opt-in via configuration
- Default values match current behavior
- Deprecation warnings for legacy APIs