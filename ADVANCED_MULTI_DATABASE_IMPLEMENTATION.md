# Advanced Multi-Database Support Implementation Summary

## Overview

This document summarizes the implementation of advanced multi-database support for Grant, addressing issue #11: Infrastructure: Advanced Multiple Database Support.

## Implemented Features

### 1. Enhanced Connection Pooling Configuration

**File: `src/grant/connection_registry.cr`**

- Enhanced `ConnectionSpec` struct with pool configuration:
  - `pool_size`: Maximum number of connections (default: 25)
  - `initial_pool_size`: Initial connections to create (default: 2)
  - `checkout_timeout`: Timeout for acquiring connections (default: 5s)
  - `retry_attempts`: Number of retry attempts (default: 1)
  - `retry_delay`: Delay between retries (default: 0.2s)

- The `build_pool_url` method automatically adds pool parameters to the database URL for crystal-db

### 2. Health Monitoring System

**File: `src/grant/health_monitor.cr`**

- `HealthMonitor` class that continuously monitors connection health
- Configurable health check intervals and timeouts
- Automatic detection of connection failures and recoveries
- Thread-safe health status tracking using atomics
- `HealthMonitorRegistry` for managing all monitors

Key features:
- Background fiber for periodic health checks
- Timeout protection for hung connections
- Logging of health state changes
- Manual health check capability

### 3. Replica Load Balancing

**File: `src/grant/replica_load_balancer.cr`**

- `ReplicaLoadBalancer` class for distributing read queries
- Multiple load balancing strategies:
  - `RoundRobinStrategy` (default)
  - `RandomStrategy`
  - `LeastConnectionsStrategy`

Features:
- Health-aware replica selection
- Automatic failover to healthy replicas
- Fallback to least recently failed replica if all unhealthy
- Dynamic replica addition/removal
- Load balancer status reporting

### 4. Enhanced Connection Registry

**Updates to: `src/grant/connection_registry.cr`**

- Integration with health monitoring and load balancing
- Automatic registration of replicas with load balancers
- Health-aware adapter selection with fallback logic
- System-wide health status reporting
- Enhanced `establish_connections` method supporting pool and health check configuration

### 5. Advanced Replica Lag Handling

**Updates to: `src/grant/connection_management.cr`**

- `ReplicaLagTracker` struct for per-database/shard tracking
- Sticky session support via `stick_to_primary` method
- Enhanced `should_use_reader?` logic that considers:
  - Replica health status
  - Time since last write
  - Sticky session periods
  - Per-database lag thresholds

### 6. Connection Configuration DSL

**Updates to: `src/grant/connection_management.cr`**

- `connection_config` macro for model-specific configuration:
  ```crystal
  connection_config(
    replica_lag_threshold: 3.seconds,
    failover_retry_attempts: 5,
    health_check_interval: 60.seconds
  )
  ```

## Usage Examples

### Basic Setup

```crystal
# Configure multiple databases with advanced features
Grant::ConnectionRegistry.establish_connections({
  "primary" => {
    adapter: Grant::Adapter::Pg,
    writer: ENV["PRIMARY_DATABASE_URL"],
    reader: ENV["PRIMARY_REPLICA_URL"],
    pool: {
      max_pool_size: 25,
      initial_pool_size: 5,
      checkout_timeout: 5.seconds,
      retry_attempts: 3,
      retry_delay: 0.2.seconds
    },
    health_check: {
      interval: 30.seconds,
      timeout: 5.seconds
    }
  }
})
```

### Model Configuration

```crystal
class User < Grant::Base
  connects_to database: "primary"
  
  connection_config(
    replica_lag_threshold: 3.seconds,
    failover_retry_attempts: 5
  )
end
```

### Advanced Features

```crystal
# Sticky sessions for critical operations
User.stick_to_primary(10.seconds)
user = User.create(email: "critical@example.com")

# Check system health
if Grant::ConnectionRegistry.system_healthy?
  puts "All connections healthy"
end

# Get load balancer status
if lb = Grant::ConnectionRegistry.get_load_balancer("primary")
  puts "Healthy replicas: #{lb.healthy_count}/#{lb.size}"
end
```

## Architecture Benefits

1. **Production Ready**: Health checks, automatic failover, and monitoring
2. **Performance**: Connection pooling and intelligent load balancing
3. **Reliability**: Automatic failover and recovery detection
4. **Flexibility**: Per-model configuration and multiple strategies
5. **Observability**: Health metrics and connection statistics
6. **Backward Compatible**: Existing code continues to work

## Implementation Status

✅ Connection pooling via crystal-db URL parameters
✅ Health monitoring with configurable intervals
✅ Load balancing with multiple strategies
✅ Automatic failover and recovery
✅ Enhanced replica lag handling
✅ Per-model connection configuration
✅ Comprehensive example usage

## Next Steps

1. The `PooledAdapter` class mentioned in the design could be implemented as a wrapper around the base adapter to provide additional pooling features beyond what crystal-db offers
2. Add metrics collection for monitoring tools
3. Implement circuit breaker pattern for failing connections
4. Add more sophisticated load balancing strategies (weighted, latency-based)
5. Create integration tests with actual database connections

## Files Modified/Created

- Created: `src/grant/health_monitor.cr`
- Created: `src/grant/replica_load_balancer.cr`
- Created: `ADVANCED_MULTI_DATABASE_DESIGN.md`
- Created: `spec/grant/advanced_multi_database_spec.cr`
- Modified: `src/grant/connection_registry.cr`
- Modified: `src/grant/connection_management.cr`
- Modified: `examples/multiple_databases.cr`

## Conclusion

This implementation provides Grant with enterprise-grade multi-database support, including all the features requested in issue #11:

- ✅ Connection pooling via crystal-db
- ✅ Role-based switching (reading/writing)
- ✅ Automatic failover
- ✅ Load balancing for replicas
- ✅ Replica lag handling

The implementation is designed to be production-ready while maintaining backward compatibility with existing Grant applications.