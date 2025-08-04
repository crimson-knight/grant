require "../spec_helper"
require "../../src/granite/health_monitor"
require "../../src/granite/replica_load_balancer"

# Test model for connection configuration DSL
class TestConfigModel < Granite::Base
  connects_to database: "test"
  
  connection_config(
    replica_lag_threshold: 5.seconds,
    failover_retry_attempts: 10,
    health_check_interval: 60.seconds,
    connection_switch_wait_period: 3000
  )
  
  table test_models
  column id : Int64, primary: true
end

describe "Advanced Multi-Database Support" do
  describe Granite::ConnectionRegistry::ConnectionSpec do
    it "stores pool configuration" do
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :primary,
        pool_size: 10,
        initial_pool_size: 2,
        checkout_timeout: 3.seconds
      )
      
      spec.pool_size.should eq 10
      spec.initial_pool_size.should eq 2
      spec.checkout_timeout.should eq 3.seconds
    end
    
    it "builds pool URL with parameters" do
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3://test.db",
        role: :primary,
        pool_size: 5
      )
      
      pool_url = spec.build_pool_url
      pool_url.should contain "max_pool_size=5"
    end
  end
  
  describe Granite::HealthMonitor do
    it "tracks connection health" do
      adapter = Granite::Adapter::Sqlite.new("test", "sqlite3::memory:")
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :primary,
        health_check_interval: 0.1.seconds,
        health_check_timeout: 0.05.seconds
      )
      
      monitor = Granite::HealthMonitor.new(adapter, spec)
      monitor.healthy?.should be_true
      
      # Test immediate health check
      monitor.check_health_now.should be_true
    end
  end
  
  describe Granite::ReplicaLoadBalancer do
    it "distributes load across replicas" do
      adapters = Array(Granite::Adapter::Base).new
      adapters << Granite::Adapter::Sqlite.new("replica1", "sqlite3::memory:")
      adapters << Granite::Adapter::Sqlite.new("replica2", "sqlite3::memory:")
      
      balancer = Granite::ReplicaLoadBalancer.new(adapters)
      balancer.size.should eq 2
      balancer.healthy_count.should eq 2
      
      # Should return different replicas on subsequent calls (round-robin)
      replica1 = balancer.next_replica
      replica1.should_not be_nil
      
      replica2 = balancer.next_replica
      replica2.should_not be_nil
    end
    
    it "supports different load balancing strategies" do
      adapters = Array(Granite::Adapter::Base).new
      adapters << Granite::Adapter::Sqlite.new("replica1", "sqlite3::memory:")
      adapters << Granite::Adapter::Sqlite.new("replica2", "sqlite3::memory:")
      
      # Test round-robin strategy
      balancer = Granite::ReplicaLoadBalancer.new(adapters, Granite::RoundRobinStrategy.new)
      balancer.strategy.should be_a(Granite::RoundRobinStrategy)
      
      # Test random strategy
      balancer.strategy = Granite::RandomStrategy.new
      balancer.strategy.should be_a(Granite::RandomStrategy)
    end
  end
  
  describe "Replica Lag Tracking" do
    it "tracks write timestamps per database" do
      tracker = Granite::ConnectionManagement::ReplicaLagTracker.new
      
      # Initially can use replica
      tracker.can_use_replica?(1.second).should be_true
      
      # After marking write, cannot use replica immediately
      tracker.mark_write
      tracker.can_use_replica?(1.second).should be_false
      
      # After waiting, can use replica again
      sleep 0.1
      tracker.can_use_replica?(0.05.seconds).should be_true
    end
    
    it "supports sticky sessions" do
      tracker = Granite::ConnectionManagement::ReplicaLagTracker.new
      
      # Stick to primary for 1 second
      tracker.stick_to_primary(1.second)
      tracker.can_use_replica?(0.seconds).should be_false
      
      # Still stuck after short wait
      sleep 0.1
      tracker.can_use_replica?(0.seconds).should be_false
    end
  end
  
  describe "Connection Configuration DSL" do
    it "allows models to configure connection behavior" do
      TestConfigModel.replica_lag_threshold.should eq 5.seconds
      TestConfigModel.failover_retry_attempts.should eq 10
      TestConfigModel.health_check_interval.should eq 60.seconds
      TestConfigModel.connection_switch_wait_period.should eq 3000
    end
  end
  
  describe "Integration" do
    it "establishes connections with full configuration" do
      Granite::ConnectionRegistry.clear_all
      
      Granite::ConnectionRegistry.establish_connection(
        database: "test_primary",
        adapter: Granite::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :writing,
        pool_size: 5,
        health_check_interval: 1.second
      )
      
      Granite::ConnectionRegistry.establish_connection(
        database: "test_primary",
        adapter: Granite::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :reading,
        pool_size: 3
      )
      
      # Should have both connections
      Granite::ConnectionRegistry.connection_exists?("test_primary", :writing).should be_true
      Granite::ConnectionRegistry.connection_exists?("test_primary", :reading).should be_true
      
      # Should have load balancer for reading role
      lb = Granite::ConnectionRegistry.get_load_balancer("test_primary")
      lb.should_not be_nil
      lb.not_nil!.size.should eq 1
    end
  end
end