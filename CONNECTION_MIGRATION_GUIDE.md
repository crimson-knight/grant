# Connection System Migration Guide

This guide helps you migrate from the old connection management system to the new Phase 1 connection infrastructure.

## Overview

The new connection system provides:
- Enhanced connection pooling with crystal-db
- Multiple database support with role-based connections
- Horizontal sharding capabilities
- Better monitoring and health checks
- Automatic read/write splitting

## Migration Steps

### Step 1: Update Your Connection Registration

#### Old Way:
```crystal
Granite::Connections << Granite::Adapter::Pg.new(name: "my_app", url: DATABASE_URL)

# Or with reader/writer split:
Granite::Connections << {
  name: "my_app",
  reader: READ_DATABASE_URL,
  writer: WRITE_DATABASE_URL,
  adapter_type: Granite::Adapter::Pg
}
```

#### New Way:
```crystal
# Simple connection
Granite::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Granite::Adapter::Pg,
  url: DATABASE_URL
)

# With reader/writer split
Granite::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Granite::Adapter::Pg,
  url: WRITE_DATABASE_URL,
  role: :writing
)

Granite::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Granite::Adapter::Pg,
  url: READ_DATABASE_URL,
  role: :reading
)

# Or use establish_connections for multiple at once
Granite::ConnectionRegistry.establish_connections({
  "my_app" => {
    adapter: Granite::Adapter::Pg,
    writer: WRITE_DATABASE_URL,
    reader: READ_DATABASE_URL,
    pool: {
      max_pool_size: 25,
      checkout_timeout: 5.seconds
    }
  }
})
```

### Step 2: Update Your Models

#### Old Way:
```crystal
class User < Granite::Base
  connection my_app
  table users
  
  column id : Int64, primary: true
  column name : String
end
```

#### New Way:
```crystal
class User < Granite::Base
  # Use the new connection management module
  include Granite::ConnectionManagementV2
  
  # Configure connections with the new DSL
  connects_to database: "my_app"
  
  # Or with roles
  connects_to(
    database: "my_app",
    config: {
      writing: "postgres://writer@localhost/myapp",
      reading: "postgres://reader@localhost/myapp"
    }
  )
  
  table users
  column id : Int64, primary: true
  column name : String
end
```

### Step 3: Connection Switching

#### Old Way:
```crystal
# Manual adapter switching
User.switch_to_reader_adapter
users = User.all
User.switch_to_writer_adapter
```

#### New Way:
```crystal
# Automatic role detection
users = User.all  # Uses reader after write delay

# Explicit role switching
User.connected_to(role: :reading) do
  users = User.all
end

# Switch database
User.connected_to(database: "archive") do
  old_users = User.where(created_at: 1.year.ago)
end

# Prevent writes
User.while_preventing_writes do
  User.all  # OK
  User.create(name: "test")  # Raises error
end
```

### Step 4: Sharded Models

#### New Feature - Not available in old system:
```crystal
class ShardedUser < Granite::Base
  include Granite::ConnectionManagementV2
  
  connects_to(
    shards: {
      shard_one: {
        writing: "postgres://shard1_writer@host1/users",
        reading: "postgres://shard1_reader@host1/users"
      },
      shard_two: {
        writing: "postgres://shard2_writer@host2/users",
        reading: "postgres://shard2_reader@host2/users"
      }
    }
  )
  
  table users
  column id : Int64, primary: true
  column name : String
  column shard_key : String
end

# Query specific shard
ShardedUser.connected_to(shard: :shard_one) do
  ShardedUser.find(123)
end
```

### Step 5: Connection Pool Configuration

#### Old Way:
```crystal
# Limited configuration through crystal-db URL parameters
url = "postgres://user:pass@localhost/db?max_pool_size=25"
```

#### New Way:
```crystal
# Rich configuration options
config = Granite::ConnectionPool::Config.new(
  max_pool_size: 50,
  initial_pool_size: 5,
  max_idle_pool_size: 10,
  checkout_timeout: 10.seconds,
  retry_attempts: 3,
  retry_delay: 0.5.seconds
)

Granite::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Granite::Adapter::Pg,
  url: DATABASE_URL,
  pool_config: config
)
```

### Step 6: Monitoring and Health Checks

#### New Features:
```crystal
# Get connection statistics
stats = Granite::ConnectionRegistry.stats
stats.each do |pool_name, pool_stats|
  puts "#{pool_name}: #{pool_stats.in_use_connections}/#{pool_stats.total_connections}"
  puts "Average checkout time: #{pool_stats.average_checkout_time}"
end

# Health check all pools
health = Granite::ConnectionRegistry.health_check
health.each do |pool_name, is_healthy|
  puts "#{pool_name}: #{is_healthy ? "✓" : "✗"}"
end

# Get all databases
databases = Granite::ConnectionRegistry.databases

# Get shards for a database
shards = Granite::ConnectionRegistry.shards_for_database("my_app")
```

## Backward Compatibility

The system maintains backward compatibility through:

1. The old `connection` macro still works but uses the new system internally
2. Old adapter properties map to the new connection pool system
3. Existing callbacks continue to function

## Breaking Changes

1. Direct adapter manipulation is discouraged - use connection contexts instead
2. Some internal APIs have changed (e.g., `@@current_adapter` is now managed differently)
3. Connection registration must happen before model usage

## Performance Improvements

The new system provides:
- Connection pooling with automatic retry logic
- Reduced connection overhead through better pool management
- Automatic read/write splitting based on time delays
- Connection health monitoring

## Troubleshooting

### Connection Not Found
```crystal
# Make sure to establish connections before using models
Granite::ConnectionRegistry.establish_connection(...)

# Then use your models
User.all
```

### Pool Timeout
```crystal
# Increase pool size or timeout
config = Granite::ConnectionPool::Config.new(
  max_pool_size: 100,
  checkout_timeout: 30.seconds
)
```

### Monitoring Connection Usage
```crystal
# Log connection stats periodically
spawn do
  loop do
    stats = Granite::ConnectionRegistry.stats
    Log.info { "Connection stats: #{stats}" }
    sleep 60.seconds
  end
end
```

## Next Steps

1. Update your connection initialization code
2. Update models to use the new DSL
3. Test connection switching behavior
4. Monitor connection pool performance
5. Consider implementing sharding if needed