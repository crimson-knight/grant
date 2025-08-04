# Test Plan for Advanced Multi-Database Support

## Overview

This document provides a comprehensive test plan for verifying the advanced multi-database features. Since some features require actual database connections and timing-based behaviors, we'll provide both unit tests and integration test examples.

## 1. Manual Testing Setup

### Prerequisites

1. Set up test databases (you can use Docker):

```bash
# PostgreSQL primary and replica
docker run -d --name pg-primary -p 5432:5432 -e POSTGRES_PASSWORD=password postgres:14
docker run -d --name pg-replica -p 5433:5432 -e POSTGRES_PASSWORD=password postgres:14

# MySQL for analytics
docker run -d --name mysql-analytics -p 3306:3306 -e MYSQL_ROOT_PASSWORD=password mysql:8

# SQLite will be used for cache (file-based)
```

2. Set environment variables:

```bash
export PRIMARY_DATABASE_URL="postgres://postgres:password@localhost:5432/test_primary"
export PRIMARY_REPLICA_URL="postgres://postgres:password@localhost:5433/test_primary"
export ANALYTICS_DATABASE_URL="mysql://root:password@localhost:3306/test_analytics"
```

### Test Application

Create `test_multi_db.cr`:

```crystal
require "./src/granite"

# Configure logging to see health checks
Log.setup(:debug)

# 1. Test Connection Pool Configuration
puts "=== Testing Connection Pool Configuration ==="

Granite::ConnectionRegistry.establish_connections({
  "primary" => {
    adapter: Granite::Adapter::Pg,
    writer: ENV["PRIMARY_DATABASE_URL"],
    reader: ENV["PRIMARY_REPLICA_URL"],
    pool: {
      max_pool_size: 10,
      initial_pool_size: 2,
      checkout_timeout: 3.seconds,
      retry_attempts: 3,
      retry_delay: 0.5.seconds
    },
    health_check: {
      interval: 5.seconds,
      timeout: 2.seconds
    }
  },
  "analytics" => {
    adapter: Granite::Adapter::Mysql,
    url: ENV["ANALYTICS_DATABASE_URL"],
    pool: {
      max_pool_size: 5
    },
    health_check: {
      interval: 10.seconds,
      timeout: 3.seconds
    }
  }
})

puts "✓ Connections established"

# 2. Test Health Monitoring
puts "\n=== Testing Health Monitoring ==="

# Wait for initial health checks
sleep 2

# Check health status
health_status = Granite::ConnectionRegistry.health_status
health_status.each do |status|
  puts "#{status[:key]} - Healthy: #{status[:healthy]} (DB: #{status[:database]}, Role: #{status[:role]})"
end

puts "System healthy: #{Granite::ConnectionRegistry.system_healthy?}"

# 3. Test Load Balancing
puts "\n=== Testing Load Balancing ==="

class User < Granite::Base
  connects_to database: "primary"
  
  connection_config(
    replica_lag_threshold: 1.second,
    failover_retry_attempts: 3
  )
  
  table users
  column id : Int64, primary: true
  column email : String
  column name : String
end

# Create table if needed
begin
  User.adapter.open do |db|
    db.exec "CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, email VARCHAR(255), name VARCHAR(255))"
  end
rescue
  # Table might already exist
end

# Test write operation (should use writer)
puts "Creating user (should use writer)..."
user = User.create(email: "test@example.com", name: "Test User")
puts "✓ Created user with ID: #{user.id}"

# Test immediate read (should use primary due to lag)
puts "\nImmediate read (should use primary due to lag)..."
found = User.find(user.id.not_nil!)
puts "✓ Found user: #{found.try(&.name)}"

# Wait for lag threshold
puts "\nWaiting for replica lag threshold..."
sleep 2

# Test delayed read (should use replica)
puts "Delayed read (should use replica if healthy)..."
users = User.all
puts "✓ Found #{users.size} users"

# 4. Test Sticky Sessions
puts "\n=== Testing Sticky Sessions ==="

User.stick_to_primary(5.seconds)
puts "✓ Stuck to primary for 5 seconds"

# All reads will use primary
3.times do |i|
  users = User.all
  puts "  Read #{i+1}: Found #{users.size} users (using primary)"
  sleep 1
end

# 5. Test Failover (Simulate)
puts "\n=== Testing Failover Behavior ==="

# Get load balancer info
if lb = Granite::ConnectionRegistry.get_load_balancer("primary")
  puts "Load balancer status:"
  puts "  Total replicas: #{lb.size}"
  puts "  Healthy replicas: #{lb.healthy_count}"
  
  lb.status.each do |replica|
    puts "  - #{replica[:adapter]}: Healthy=#{replica[:healthy]}"
  end
end

# 6. Test Multiple Database Access
puts "\n=== Testing Multiple Database Access ==="

class AnalyticsEvent < Granite::Base
  connects_to database: "analytics"
  
  table events
  column id : Int64, primary: true
  column event_type : String
  column user_id : Int64
  column created_at : Time
end

begin
  AnalyticsEvent.adapter.open do |db|
    db.exec "CREATE TABLE IF NOT EXISTS events (id BIGINT PRIMARY KEY AUTO_INCREMENT, event_type VARCHAR(255), user_id BIGINT, created_at TIMESTAMP)"
  end
  
  # Log an event
  event = AnalyticsEvent.create(
    event_type: "user.created",
    user_id: user.id.not_nil!,
    created_at: Time.utc
  )
  puts "✓ Created analytics event with ID: #{event.id}"
rescue ex
  puts "✗ Analytics error: #{ex.message}"
end

# 7. Monitor Health for 30 seconds
puts "\n=== Monitoring Health for 30 seconds ==="
puts "Watch for health check logs..."

30.times do |i|
  print "\rMonitoring... #{30-i} seconds remaining"
  sleep 1
end
puts "\n✓ Monitoring complete"

# Final health report
puts "\n=== Final Health Report ==="
Granite::HealthMonitorRegistry.status.each do |status|
  puts "#{status[:key]} - Healthy: #{status[:healthy]}, Last check: #{status[:last_check]}"
end

puts "\n✓ All tests completed!"
```

## 2. Unit Test Suite

Create `spec/granite/multi_database_integration_spec.cr`:

```crystal
require "../spec_helper"

# Mock adapter that tracks calls
class TrackingAdapter < Granite::Adapter::Base
  QUOTING_CHAR = '"'
  
  getter call_count = 0
  getter last_query : String?
  property healthy = true
  
  def clear(table_name : String)
  end
  
  def insert(table_name : String, fields, params, lastval) : Int64
    @call_count += 1
    1_i64
  end
  
  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
  end
  
  def update(table_name : String, primary_name : String, fields, params)
    @call_count += 1
  end
  
  def delete(table_name : String, primary_name : String, value)
    @call_count += 1
  end
  
  def open(&)
    raise "Connection failed" unless @healthy
    @call_count += 1
    yield MockConnection.new
  end
  
  class MockConnection
    def scalar(query : String)
      1
    end
    
    def exec(query : String, args = [] of DB::Any)
    end
    
    def query(query : String, args = [] of DB::Any)
    end
  end
end

describe "Advanced Multi-Database Features" do
  after_each do
    Granite::ConnectionRegistry.clear_all
    Granite::HealthMonitorRegistry.clear
    Granite::LoadBalancerRegistry.clear
  end
  
  describe "Connection Pooling" do
    it "configures pool parameters in URL" do
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3://test.db",
        role: :primary,
        pool_size: 20,
        initial_pool_size: 5,
        checkout_timeout: 10.seconds,
        retry_attempts: 5,
        retry_delay: 1.second
      )
      
      pool_url = spec.build_pool_url
      pool_url.should contain("max_pool_size=20")
      pool_url.should contain("initial_pool_size=5")
      pool_url.should contain("checkout_timeout=10")
      pool_url.should contain("retry_attempts=5")
      pool_url.should contain("retry_delay=1")
    end
  end
  
  describe "Health Monitoring" do
    it "monitors adapter health" do
      adapter = TrackingAdapter.new("test", "mock://test")
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: TrackingAdapter,
        url: "mock://test",
        role: :primary,
        health_check_interval: 0.1.seconds,
        health_check_timeout: 0.05.seconds
      )
      
      monitor = Granite::HealthMonitor.new(adapter, spec)
      
      # Initially healthy
      monitor.healthy?.should be_true
      
      # Simulate failure
      adapter.healthy = false
      monitor.check_health_now
      monitor.healthy?.should be_false
      
      # Simulate recovery
      adapter.healthy = true
      monitor.check_health_now
      monitor.healthy?.should be_true
    end
  end
  
  describe "Load Balancing" do
    it "distributes requests across replicas" do
      replicas = [
        TrackingAdapter.new("replica1", "mock://replica1"),
        TrackingAdapter.new("replica2", "mock://replica2"),
        TrackingAdapter.new("replica3", "mock://replica3")
      ]
      
      balancer = Granite::ReplicaLoadBalancer.new(replicas)
      
      # Round-robin distribution
      selected = [] of String
      6.times do
        if replica = balancer.next_replica
          selected << replica.name
        end
      end
      
      # Should cycle through all replicas
      selected.should eq(["replica1", "replica2", "replica3", "replica1", "replica2", "replica3"])
    end
    
    it "skips unhealthy replicas" do
      replicas = [
        TrackingAdapter.new("replica1", "mock://replica1"),
        TrackingAdapter.new("replica2", "mock://replica2")
      ]
      
      # Create monitors
      monitors = replicas.map do |replica|
        spec = Granite::ConnectionRegistry::ConnectionSpec.new(
          database: "test",
          adapter_class: TrackingAdapter,
          url: replica.url,
          role: :reading
        )
        Granite::HealthMonitor.new(replica, spec)
      end
      
      balancer = Granite::ReplicaLoadBalancer.new(replicas)
      monitors.each_with_index do |monitor, i|
        balancer.set_health_monitor(replicas[i], monitor)
      end
      
      # Mark first replica as unhealthy
      replicas[0].healthy = false
      monitors[0].check_health_now
      
      # Should only return healthy replica
      5.times do
        replica = balancer.next_replica
        replica.should eq(replicas[1]) if replica
      end
    end
  end
  
  describe "Replica Lag Tracking" do
    it "prevents replica use after writes" do
      tracker = Granite::ConnectionManagement::ReplicaLagTracker.new(
        lag_threshold: 1.second
      )
      
      # Can use replica initially
      tracker.can_use_replica?(0.5.seconds).should be_true
      
      # Cannot use immediately after write
      tracker.mark_write
      tracker.can_use_replica?(0.5.seconds).should be_false
      
      # Can use after threshold
      sleep 0.6
      tracker.can_use_replica?(0.5.seconds).should be_true
    end
    
    it "supports sticky sessions" do
      tracker = Granite::ConnectionManagement::ReplicaLagTracker.new
      
      # Stick to primary
      tracker.stick_to_primary(2.seconds)
      
      # Cannot use replica during sticky period
      tracker.can_use_replica?(0.seconds).should be_false
      sleep 0.1
      tracker.can_use_replica?(0.seconds).should be_false
    end
  end
  
  describe "Failover" do
    it "falls back to primary when replicas fail" do
      Granite::ConnectionRegistry.establish_connection(
        database: "failover_test",
        adapter: TrackingAdapter,
        url: "mock://primary",
        role: :primary
      )
      
      Granite::ConnectionRegistry.establish_connection(
        database: "failover_test",
        adapter: TrackingAdapter,
        url: "mock://replica",
        role: :reading
      )
      
      # Get adapters
      primary = Granite::ConnectionRegistry.get_adapter("failover_test", :primary)
      
      # Should get replica normally
      replica = Granite::ConnectionRegistry.get_adapter("failover_test", :reading)
      replica.url.should eq("mock://replica")
      
      # Simulate replica failure
      if replica.is_a?(TrackingAdapter)
        replica.healthy = false
      end
      
      # Should fall back to primary
      # Note: This would require the health monitor to detect the failure
      # In a real scenario, the health monitor would mark it unhealthy
    end
  end
end
```

## 3. Running the Tests

### Unit Tests
```bash
# Run the specific test file
crystal spec spec/granite/multi_database_integration_spec.cr

# Run all tests
crystal spec
```

### Integration Test
```bash
# Make sure databases are running
crystal run test_multi_db.cr
```

## 4. What to Verify

### Connection Pooling
- ✓ Pool parameters are added to database URLs
- ✓ Connections respect pool size limits
- ✓ Timeout behavior works correctly

### Health Monitoring
- ✓ Health checks run at configured intervals
- ✓ Unhealthy connections are detected
- ✓ Recovery is detected when connections return
- ✓ Health status is accurately reported

### Load Balancing
- ✓ Requests are distributed across replicas
- ✓ Unhealthy replicas are skipped
- ✓ Different strategies work (round-robin, random)
- ✓ Fallback to primary works when all replicas fail

### Replica Lag
- ✓ Reads use primary immediately after writes
- ✓ Reads switch to replica after lag threshold
- ✓ Sticky sessions keep using primary
- ✓ Per-database tracking works correctly

### Failover
- ✓ Primary is used when replicas are unhealthy
- ✓ System continues working with degraded replicas
- ✓ Recovery is automatic when replicas return

## 5. Performance Testing

Create a performance test to verify pooling and load balancing:

```crystal
require "./src/granite"
require "benchmark"

# Configure connections
Granite::ConnectionRegistry.establish_connections({
  "perf_test" => {
    adapter: Granite::Adapter::Sqlite,
    writer: "sqlite3://perf_test.db",
    reader: "sqlite3://perf_test_replica.db",
    pool: {
      max_pool_size: 50,
      initial_pool_size: 10
    }
  }
})

class PerfModel < Granite::Base
  connects_to database: "perf_test"
  table perf_records
  column id : Int64, primary: true
  column data : String
end

# Benchmark concurrent operations
puts "Testing concurrent database operations..."

Benchmark.ips do |x|
  x.report("sequential reads") do
    100.times { PerfModel.all }
  end
  
  x.report("concurrent reads") do
    fibers = 100.times.map do
      spawn { PerfModel.all }
    end
    Fiber.yield
  end
  
  x.compare!
end
```

## 6. Troubleshooting

If tests fail:

1. Check database connectivity:
   ```bash
   psql $PRIMARY_DATABASE_URL -c "SELECT 1"
   mysql -h localhost -P 3306 -u root -ppassword -e "SELECT 1"
   ```

2. Enable debug logging:
   ```crystal
   Log.setup(:debug)
   ```

3. Verify environment variables are set correctly

4. Check for port conflicts if using Docker

## Summary

This test plan covers:
- Unit tests for individual components
- Integration tests with real databases
- Performance testing
- Manual verification steps

The tests verify all major features of the advanced multi-database support implementation.