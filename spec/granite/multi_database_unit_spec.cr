require "../spec_helper"

# Test models outside of describe blocks to avoid compilation errors
class TestMultiDbModel < Granite::Base
  connects_to database: "test"
  table test_records
  column id : Int64, primary: true
  column name : String
end

describe "Multi-Database Unit Tests" do
  describe "ConnectionSpec" do
    it "stores all configuration values" do
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test_db",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3://test.db",
        role: :primary,
        shard: :us_east,
        pool_size: 30,
        initial_pool_size: 5,
        checkout_timeout: 10.seconds,
        retry_attempts: 5,
        retry_delay: 0.5.seconds,
        health_check_interval: 60.seconds,
        health_check_timeout: 10.seconds
      )
      
      spec.database.should eq("test_db")
      spec.role.should eq(:primary)
      spec.shard.should eq(:us_east)
      spec.pool_size.should eq(30)
      spec.initial_pool_size.should eq(5)
      spec.checkout_timeout.should eq(10.seconds)
      spec.retry_attempts.should eq(5)
      spec.retry_delay.should eq(0.5.seconds)
      spec.health_check_interval.should eq(60.seconds)
      spec.health_check_timeout.should eq(10.seconds)
    end
    
    it "generates correct connection key" do
      spec1 = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "mydb",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3://test.db",
        role: :reading
      )
      spec1.connection_key.should eq("mydb:reading")
      
      spec2 = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "mydb",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3://test.db",
        role: :writing,
        shard: :us_west
      )
      spec2.connection_key.should eq("mydb:writing:us_west")
    end
    
    it "builds pool URL with parameters" do
      spec = Granite::ConnectionRegistry::ConnectionSpec.new(
        database: "test",
        adapter_class: Granite::Adapter::Sqlite,
        url: "sqlite3://test.db?foo=bar",
        role: :primary,
        pool_size: 15,
        checkout_timeout: 7.seconds
      )
      
      url = spec.build_pool_url
      url.should contain("foo=bar")
      url.should contain("max_pool_size=15")
      url.should contain("checkout_timeout=7")
    end
  end
  
  describe "ReplicaLagTracker" do
    it "tracks write operations" do
      tracker = Granite::ConnectionManagement::ReplicaLagTracker.new
      
      # Initially, enough time has passed to use replica
      tracker.can_use_replica?(1.second).should be_true
      
      # After a write, cannot use replica
      tracker.mark_write
      tracker.can_use_replica?(2.seconds).should be_false
      
      # After waiting, can use replica
      sleep 2.1
      tracker.can_use_replica?(2.seconds).should be_true
    end
    
    it "implements sticky sessions" do
      tracker = Granite::ConnectionManagement::ReplicaLagTracker.new
      
      # Stick to primary for 3 seconds
      tracker.stick_to_primary(3.seconds)
      
      # Cannot use replica during sticky period
      tracker.can_use_replica?(0.seconds).should be_false
      
      # Even with no recent writes
      sleep 1
      tracker.can_use_replica?(0.seconds).should be_false
    end
  end
  
  describe "Load Balancing Strategies" do
    it "round-robin cycles through indices" do
      strategy = Granite::RoundRobinStrategy.new
      
      # Should cycle 0, 1, 2, 0, 1, 2...
      strategy.next_index(3).should eq(0)
      strategy.next_index(3).should eq(1)
      strategy.next_index(3).should eq(2)
      strategy.next_index(3).should eq(0)
      strategy.next_index(3).should eq(1)
    end
    
    it "random strategy returns valid indices" do
      strategy = Granite::RandomStrategy.new
      
      100.times do
        index = strategy.next_index(5)
        index.should be >= 0
        index.should be < 5
      end
    end
    
    it "least connections strategy tracks connections" do
      strategy = Granite::LeastConnectionsStrategy.new
      
      # Initially all have 0 connections, should return first
      strategy.next_index(3).should eq(0)
      
      # Now index 0 has 1 connection, should return 1
      strategy.next_index(3).should eq(1)
      
      # Now 0 and 1 have 1 connection each, should return 2
      strategy.next_index(3).should eq(2)
      
      # Release connection from index 0
      strategy.release_connection(0)
      
      # Should return 0 again (now has 0 connections)
      strategy.next_index(3).should eq(0)
    end
  end
  
  describe "ConnectionRegistry with establish_connections" do
    after_each do
      Granite::ConnectionRegistry.clear_all
    end
    
    it "parses pool configuration from Hash" do
      config = {
        "test_db" => {
          adapter: Granite::Adapter::Sqlite,
          url: "sqlite3://test.db",
          pool: {
            max_pool_size: 15,
            checkout_timeout: 8.seconds
          }
        }
      }
      
      Granite::ConnectionRegistry.establish_connections(config)
      
      # Verify connection was established
      Granite::ConnectionRegistry.connection_exists?("test_db", :primary).should be_true
    end
    
    it "establishes writer and reader connections" do
      config = {
        "multi_db" => {
          adapter: Granite::Adapter::Sqlite,
          writer: "sqlite3://writer.db",
          reader: "sqlite3://reader.db"
        }
      }
      
      Granite::ConnectionRegistry.establish_connections(config)
      
      Granite::ConnectionRegistry.connection_exists?("multi_db", :writing).should be_true
      Granite::ConnectionRegistry.connection_exists?("multi_db", :reading).should be_true
    end
  end
  
  describe "System Health" do
    after_each do
      Granite::ConnectionRegistry.clear_all
      Granite::HealthMonitorRegistry.clear
    end
    
    it "reports connection health status" do
      Granite::ConnectionRegistry.establish_connection(
        database: "health_test",
        adapter: Granite::Adapter::Sqlite,
        url: "sqlite3::memory:",
        role: :primary
      )
      
      status = Granite::ConnectionRegistry.health_status
      status.size.should eq(1)
      status[0][:database].should eq("health_test")
      status[0][:role].should eq(:primary)
      status[0][:healthy].should be_true
    end
  end
end