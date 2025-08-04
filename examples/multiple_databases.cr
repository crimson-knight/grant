require "../src/granite"

# Example: Multiple Database Configuration with Grant

# 1. Set up multiple databases with advanced configuration
Granite::ConnectionRegistry.establish_connections({
  "primary" => {
    adapter: Granite::Adapter::Pg,
    writer: ENV["PRIMARY_DATABASE_URL"],
    reader: ENV["PRIMARY_REPLICA_URL"]?,
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
  },
  "analytics" => {
    adapter: Granite::Adapter::Pg,
    url: ENV["ANALYTICS_DATABASE_URL"],
    pool: {
      max_pool_size: 10,
      checkout_timeout: 3.seconds
    },
    health_check: {
      interval: 60.seconds,
      timeout: 10.seconds
    }
  },
  "cache" => {
    adapter: Granite::Adapter::Sqlite,
    url: "sqlite3://./cache.db",
    pool: {
      max_pool_size: 5
    }
  }
})

# 2. Models with different database connections
class User < Granite::Base
  # Connect to primary database with read/write splitting
  connects_to database: "primary"
  
  # Configure connection behavior
  connection_config(
    replica_lag_threshold: 3.seconds,
    failover_retry_attempts: 5,
    connection_switch_wait_period: 2500 # milliseconds
  )
  
  table users
  column id : Int64, primary: true
  column email : String
  column name : String
  column created_at : Time
end

class AnalyticsEvent < Granite::Base
  # Connect to analytics database
  connects_to database: "analytics"
  
  table events
  column id : Int64, primary: true
  column user_id : Int64
  column event_type : String
  column properties : JSON::Any
  column occurred_at : Time
end

class CachedResult < Granite::Base
  # Connect to local SQLite cache
  connects_to database: "cache"
  
  table cached_results
  column id : Int64, primary: true
  column key : String
  column value : String
  column expires_at : Time
end

# 3. Using multiple databases
puts "=== Multiple Database Example ==="

# Create a user (uses primary writer)
user = User.create(
  email: "user@example.com",
  name: "Test User"
)
puts "Created user: #{user.id}"

# Read from replica after delay
sleep 2.1 # Wait for replication lag
User.connected_to(role: :reading) do
  users = User.all
  puts "Found #{users.size} users on replica"
end

# Log analytics event
event = AnalyticsEvent.create(
  user_id: user.id.not_nil!,
  event_type: "user.created",
  properties: JSON.parse(%({"source": "example"})),
  occurred_at: Time.utc
)
puts "Logged analytics event: #{event.id}"

# Cache a result
cached = CachedResult.create(
  key: "user:#{user.id}:summary",
  value: {id: user.id, name: user.name}.to_json,
  expires_at: 1.hour.from_now
)
puts "Cached result: #{cached.key}"

# 4. Switch databases dynamically
puts "\n=== Dynamic Database Switching ==="

# Query different database temporarily
User.connected_to(database: "analytics") do
  # This would normally fail since users table doesn't exist in analytics DB
  # but demonstrates the switching capability
  puts "Switched to analytics database"
end

# 5. Prevent writes example
puts "\n=== Write Prevention ==="

User.while_preventing_writes do
  # Reading is allowed
  users = User.all
  puts "Can read: found #{users.size} users"
  
  # Writing would raise an error
  # User.create(email: "blocked@example.com", name: "Blocked")
end

# 6. Sharded database example
class ShardedOrder < Granite::Base
  include Granite::ConnectionManagementV2
  
  connects_to(
    shards: {
      us_east: {
        writing: ENV["US_EAST_SHARD_URL"],
        reading: ENV["US_EAST_REPLICA_URL"]
      },
      us_west: {
        writing: ENV["US_WEST_SHARD_URL"],
        reading: ENV["US_WEST_REPLICA_URL"]
      },
      eu: {
        writing: ENV["EU_SHARD_URL"],
        reading: ENV["EU_REPLICA_URL"]
      }
    }
  )
  
  table orders
  column id : Int64, primary: true
  column user_id : Int64
  column region : String
  column total : Float64
  
  # Determine shard based on region
  def self.shard_for_region(region : String) : Symbol
    case region
    when "US-EAST" then :us_east
    when "US-WEST" then :us_west
    when "EU"      then :eu
    else               :us_east # default
    end
  end
end

puts "\n=== Sharded Database Example ==="

# Create orders in different shards
["US-EAST", "US-WEST", "EU"].each do |region|
  shard = ShardedOrder.shard_for_region(region)
  
  ShardedOrder.connected_to(shard: shard) do
    order = ShardedOrder.create(
      user_id: user.id.not_nil!,
      region: region,
      total: Random.rand(100.0..1000.0)
    )
    puts "Created order #{order.id} in #{region} shard"
  end
end

# Query specific shard
ShardedOrder.connected_to(shard: :us_east) do
  orders = ShardedOrder.where(region: "US-EAST").select
  puts "Found #{orders.size} orders in US-EAST shard"
end

puts "\n=== Connection Statistics ==="
Granite::ConnectionRegistry.adapter_names.each do |name|
  puts "Adapter: #{name}"
end

# 7. Advanced Features: Health Monitoring and Load Balancing
puts "\n=== Health Monitoring ==="

# Check system health
if Granite::ConnectionRegistry.system_healthy?
  puts "All connections are healthy"
else
  puts "Some connections are unhealthy"
end

# Get detailed health status
Granite::ConnectionRegistry.health_status.each do |status|
  puts "#{status[:key]} - Healthy: #{status[:healthy]} (Database: #{status[:database]}, Role: #{status[:role]})"
end

# Check load balancer status for primary database
if lb = Granite::ConnectionRegistry.get_load_balancer("primary")
  puts "\nPrimary database load balancer:"
  puts "Total replicas: #{lb.size}"
  puts "Healthy replicas: #{lb.healthy_count}"
  
  lb.status.each do |replica|
    puts "  #{replica[:adapter]} - Healthy: #{replica[:healthy]}"
  end
end

# 8. Sticky Sessions Example
puts "\n=== Sticky Sessions Example ==="

# Force primary usage for critical operations
User.stick_to_primary(10.seconds)
user = User.create(email: "critical@example.com", name: "Critical User")
puts "Created critical user with sticky primary connection"

# Subsequent reads will use primary for 10 seconds
found_user = User.find(user.id.not_nil!)
puts "Found user on primary due to sticky session"

# 9. Manual Health Check
puts "\n=== Manual Health Check ==="

# Trigger immediate health check for all connections
Granite::HealthMonitorRegistry.status.each do |monitor_status|
  puts "Connection #{monitor_status[:key]} - Healthy: #{monitor_status[:healthy]}, Last check: #{monitor_status[:last_check]}"
end

puts "\n=== Example Complete ==="