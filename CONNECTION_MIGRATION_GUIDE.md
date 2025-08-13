# Connection System Migration Guide

This guide helps you migrate to the new simplified connection management system in Grant.

## Overview

The new connection system is now built directly into Grant::Base and provides:
- Multiple database support with role-based connections (reading/writing)
- Horizontal sharding capabilities
- Automatic read/write splitting based on time delays
- Connection context switching
- Write prevention mode

## Migration Steps

### Step 1: Update Your Connection Registration

#### Old Way:
```crystal
Grant::Connections << Grant::Adapter::Pg.new(name: "my_app", url: DATABASE_URL)

# Or with reader/writer split:
Grant::Connections << {
  name: "my_app",
  reader: READ_DATABASE_URL,
  writer: WRITE_DATABASE_URL,
  adapter_type: Grant::Adapter::Pg
}
```

#### New Way:
```crystal
# Simple connection
Grant::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Grant::Adapter::Pg,
  url: DATABASE_URL
)

# With reader/writer split
Grant::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Grant::Adapter::Pg,
  url: WRITE_DATABASE_URL,
  role: :writing
)

Grant::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Grant::Adapter::Pg,
  url: READ_DATABASE_URL,
  role: :reading
)

# Or use establish_connections for multiple at once
Grant::ConnectionRegistry.establish_connections({
  "my_app" => {
    adapter: Grant::Adapter::Pg,
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
class User < Grant::Base
  connection my_app
  table users
  
  column id : Int64, primary: true
  column name : String
end
```

#### New Way:
```crystal
class User < Grant::Base
  # Connection management is now built-in - no module needed!
  
  # Configure connections with the DSL
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

#### New Feature - Sharding:
```crystal
class ShardedUser < Grant::Base
  # No module needed - sharding is built-in!
  
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
config = Grant::ConnectionPool::Config.new(
  max_pool_size: 50,
  initial_pool_size: 5,
  max_idle_pool_size: 10,
  checkout_timeout: 10.seconds,
  retry_attempts: 3,
  retry_delay: 0.5.seconds
)

Grant::ConnectionRegistry.establish_connection(
  database: "my_app",
  adapter: Grant::Adapter::Pg,
  url: DATABASE_URL,
  pool_config: config
)
```

### Step 6: Monitoring and Health Checks

#### New Features:
```crystal
# Get connection statistics
stats = Grant::ConnectionRegistry.stats
stats.each do |pool_name, pool_stats|
  puts "#{pool_name}: #{pool_stats.in_use_connections}/#{pool_stats.total_connections}"
  puts "Average checkout time: #{pool_stats.average_checkout_time}"
end

# Health check all pools
health = Grant::ConnectionRegistry.health_check
health.each do |pool_name, is_healthy|
  puts "#{pool_name}: #{is_healthy ? "✓" : "✗"}"
end

# Get all databases
databases = Grant::ConnectionRegistry.databases

# Get shards for a database
shards = Grant::ConnectionRegistry.shards_for_database("my_app")
```

## Breaking Changes

1. Connection management is now built into Grant::Base - no separate module needed
2. The `connection` macro is simplified and just sets the database name
3. Direct adapter manipulation should be replaced with connection contexts
4. Connection registration must happen before model usage
5. The old reader/writer adapter properties are replaced by the new role-based system

## Benefits of the New System

1. **Simpler API** - No need to include extra modules
2. **More Powerful** - Built-in support for sharding and multiple databases
3. **Better Performance** - Automatic read/write splitting with configurable delays
4. **Type Safe** - Connection contexts are properly typed

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
Grant::ConnectionRegistry.establish_connection(...)

# Then use your models
User.all
```

### Pool Timeout
```crystal
# Increase pool size or timeout
config = Grant::ConnectionPool::Config.new(
  max_pool_size: 100,
  checkout_timeout: 30.seconds
)
```

### Monitoring Connection Usage
```crystal
# Log connection stats periodically
spawn do
  loop do
    stats = Grant::ConnectionRegistry.stats
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