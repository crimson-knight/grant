require "../spec_helper"
require "../../src/grant"

# Enable test mode to prevent background fiber issues
Grant::HealthMonitor.test_mode = true

# Test model for integration tests
class IntegrationTestModel < Grant::Base
  connects_to database: "model_test"
  
  table integration_tests
  column id : Int64, primary: true
  column name : String
end

describe "Multi-Database Integration" do
  before_each do
    Grant::ConnectionRegistry.clear_all
  end
  
  after_each do
    Grant::ConnectionRegistry.clear_all
  end
  
  describe "Connection pooling" do
    it "establishes connections with pool configuration" do
      Grant::ConnectionRegistry.establish_connection(
        database: "test_db",
        adapter: Grant::Adapter::Sqlite,
        url: "sqlite3::memory:",
        pool_size: 10,
        initial_pool_size: 2,
        checkout_timeout: 3.seconds
      )
      
      # Verify connection was established
      Grant::ConnectionRegistry.connection_exists?("test_db", :primary).should be_true
    end
    
    it "establishes multiple connections from config" do
      config = {
        "primary_db" => {
          adapter: Grant::Adapter::Sqlite,
          url: "sqlite3::memory:",
          pool: {
            max_pool_size: 20,
            initial_pool_size: 5
          }
        },
        "secondary_db" => {
          adapter: Grant::Adapter::Sqlite,
          writer: "sqlite3::memory:",
          reader: "sqlite3::memory:",
          pool: {
            max_pool_size: 15
          }
        }
      }
      
      Grant::ConnectionRegistry.establish_connections(config)
      
      Grant::ConnectionRegistry.connection_exists?("primary_db", :primary).should be_true
      Grant::ConnectionRegistry.connection_exists?("secondary_db", :writing).should be_true
      Grant::ConnectionRegistry.connection_exists?("secondary_db", :reading).should be_true
      
      Grant::ConnectionRegistry.databases.should contain("primary_db")
      Grant::ConnectionRegistry.databases.should contain("secondary_db")
    end
  end
  
  describe "Health monitoring" do
    it "creates health monitors without starting background fibers in test mode" do
      # Register a connection (health monitor will be created but not started)
      adapter = Grant::Adapter::Sqlite.new("test", "sqlite3::memory:")
      spec = Grant::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: Grant::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :primary
      )
      
      Grant::HealthMonitorRegistry.register("test:primary", adapter, spec)
      
      monitor = Grant::HealthMonitorRegistry.get("test:primary")
      monitor.should_not be_nil
      
      # Can still check health manually
      monitor.not_nil!.check_health_now.should be_true
      monitor.not_nil!.healthy?.should be_true
    end
    
    it "tracks health status across multiple connections" do
      # Register multiple connections
      3.times do |i|
        adapter = Grant::Adapter::Sqlite.new("test#{i}", "sqlite3::memory:")
        spec = Grant::ConnectionRegistry::ConnectionSpec.new(
          database: "test#{i}",
          adapter_class: Grant::Adapter::Sqlite,
          url: "sqlite3::memory:",
          role: :primary
        )
        Grant::HealthMonitorRegistry.register("test#{i}:primary", adapter, spec)
      end
      
      # All should be healthy
      Grant::HealthMonitorRegistry.all_healthy?.should be_true
      Grant::HealthMonitorRegistry.healthy_connections.size.should eq(3)
      Grant::HealthMonitorRegistry.unhealthy_connections.should be_empty
    end
  end
  
  describe "Load balancing" do
    it "distributes requests across read replicas" do
      # Create a load balancer with multiple replicas
      adapters = Array.new(3) do |i|
        Grant::Adapter::Sqlite.new("replica#{i}", "sqlite3::memory:")
      end
      
      load_balancer = Grant::ReplicaLoadBalancer.new(adapters)
      
      # Track distribution
      distribution = Hash(Grant::Adapter::Base, Int32).new(0)
      100.times do
        if replica = load_balancer.next_replica
          distribution[replica] = distribution[replica] + 1
        end
      end
      
      # Should have distributed across all replicas
      distribution.size.should eq(3)
      distribution.values.min.should be > 20  # Reasonable distribution
    end
    
    it "skips unhealthy replicas" do
      # Create replicas with monitors
      adapters = Array.new(3) do |i|
        adapter = Grant::Adapter::Sqlite.new("replica#{i}", "sqlite3::memory:")
        spec = Grant::ConnectionRegistry::ConnectionSpec.new(
          database: "test",
          adapter_class: Grant::Adapter::Sqlite,
          url: "sqlite3::memory:",
          role: :reading
        )
        monitor = Grant::HealthMonitor.new(adapter, spec)
        
        # Make second replica unhealthy
        if i == 1
          monitor.@healthy.set(false)
        end
        
        Grant::HealthMonitorRegistry.register("replica#{i}", adapter, spec)
        adapter
      end
      
      load_balancer = Grant::ReplicaLoadBalancer.new(adapters)
      
      # Add monitors to load balancer
      adapters.each_with_index do |adapter, i|
        monitor = Grant::HealthMonitorRegistry.get("replica#{i}")
        load_balancer.add_replica(adapter, monitor)
      end
      
      # Should only return healthy replicas
      selected_replicas = Set(String).new
      10.times do
        if replica = load_balancer.next_replica
          selected_replicas.add(replica.name)
        end
      end
      
      selected_replicas.should_not contain("replica1")
      selected_replicas.should contain("replica0")
      selected_replicas.should contain("replica2")
    end
  end
  
  describe "Replica lag tracking" do
    it "prevents reads from lagged replicas" do
      tracker = Grant::ConnectionManagement::ReplicaLagTracker.new(lag_threshold: 2.seconds)
      
      # Initially can use replica
      tracker.can_use_replica?(1.second).should be_true
      
      # After write, cannot use replica
      tracker.mark_write
      tracker.can_use_replica?(1.second).should be_false
      
      # After waiting, can use replica again
      sleep 2.1.seconds
      tracker.can_use_replica?(2.seconds).should be_true
    end
  end
  
  describe "Connection failover" do
    it "falls back to primary when replicas unavailable" do
      Grant::ConnectionRegistry.establish_connection(
        database: "failover_test",
        adapter: Grant::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :primary
      )
      
      # Try to get a reading connection (not established)
      adapter = Grant::ConnectionRegistry.get_adapter("failover_test", :reading)
      
      # Should fall back to primary
      adapter.should_not be_nil
      # Should have gotten the primary adapter as fallback
      adapter.name.should eq("failover_test:primary")
    end
    
    it "falls back to writer when reader unavailable" do
      Grant::ConnectionRegistry.establish_connection(
        database: "split_test",
        adapter: Grant::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :writing
      )
      
      # Try to get a reading connection
      adapter = Grant::ConnectionRegistry.get_adapter("split_test", :reading)
      
      # Should fall back to writer
      adapter.should_not be_nil
      # Should have gotten the writer adapter as fallback
      adapter.name.should eq("split_test:writing")
    end
  end
  
  describe "Model integration" do
    it "uses configured database connections" do
      # Set up a test database
      Grant::ConnectionRegistry.establish_connection(
        database: "model_test",
        adapter: Grant::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :primary
      )
      
      # Verify model uses the configured database
      IntegrationTestModel.database_name.should eq("model_test")
    end
  end
end