require "../spec_helper"

# Model for testing connection management
class ConnectionTestModel < Grant::Base
  table connection_test
  
  column id : Int64, primary: true
  column name : String
  
  # Configure multiple connections
  connects_to config: {writing: "primary", reading: "replica"}
end

# Model for testing sharded connections
class ShardedModel < Grant::Base
  table sharded_models
  
  column id : Int64, primary: true
  column name : String
  
  connects_to shards: {
    shard_one: {writing: "shard1_primary", reading: "shard1_replica"},
    shard_two: {writing: "shard2_primary", reading: "shard2_replica"}
  }
end

# Model without connection configuration for testing fallback
class UnConfiguredModel < Grant::Base
  table unconfigured
  column id : Int64, primary: true
end

describe Grant::ConnectionManagement do
  describe "connection_switch_wait_period" do
    it "delegates to Grant::Connections" do
      # Save original value
      original_value = Grant::Connections.connection_switch_wait_period
      
      # Test getter
      ConnectionTestModel.connection_switch_wait_period.should eq original_value
      
      # Test setter
      ConnectionTestModel.connection_switch_wait_period = 5000
      Grant::Connections.connection_switch_wait_period.should eq 5000
      ConnectionTestModel.connection_switch_wait_period.should eq 5000
      
      # Restore original value
      Grant::Connections.connection_switch_wait_period = original_value
    end
  end
  
  describe "role-based connections" do
    it "tracks write operations" do
      # Initial state - no recent writes
      ConnectionTestModel.last_write_time.should be_a(Time::Span)
      
      # Mark write operation
      ConnectionTestModel.mark_write_operation
      after_write = ConnectionTestModel.last_write_time
      
      # Time should be updated
      after_write.should be >= Time.monotonic - 1.second
    end
    
    it "determines current role based on write timing" do
      # Configure connections
      ConnectionTestModel.connection_config = {:writing => "primary", :reading => "replica"}
      
      # Right after write, should use primary
      ConnectionTestModel.mark_write_operation
      ConnectionTestModel.current_role.should eq :primary
      
      # Set wait period to 50ms for testing
      original_wait = ConnectionTestModel.connection_switch_wait_period
      ConnectionTestModel.connection_switch_wait_period = 50
      
      # Wait for switch period
      sleep 0.1.seconds
      
      # Should now use reading role
      ConnectionTestModel.current_role.should eq :reading
      
      # Restore original wait period
      ConnectionTestModel.connection_switch_wait_period = original_wait
    end
  end
  
  describe "connected_to" do
    it "switches database context within a block" do
      original_db = ConnectionTestModel.current_database
      
      ConnectionTestModel.connected_to(database: "other_db") do
        ConnectionTestModel.current_database.should eq "other_db"
      end
      
      # Should restore after block
      ConnectionTestModel.current_database.should eq original_db
    end
    
    it "switches role within a block" do
      ConnectionTestModel.connected_to(role: :reading) do
        ConnectionTestModel.current_role.should eq :reading
      end
      
      # Role selection should be based on timing again
      ConnectionTestModel.mark_write_operation
      ConnectionTestModel.current_role.should eq :primary
    end
    
    it "prevents writes when specified" do
      ConnectionTestModel.preventing_writes?.should be_false
      
      ConnectionTestModel.connected_to(prevent_writes: true) do
        ConnectionTestModel.preventing_writes?.should be_true
      end
      
      ConnectionTestModel.preventing_writes?.should be_false
    end
    
    it "supports sharded connections" do
      ShardedModel.current_shard.should be_nil
      
      ShardedModel.connected_to(shard: :shard_one) do
        ShardedModel.current_shard.should eq :shard_one
      end
      
      ShardedModel.current_shard.should be_nil
    end
  end
  
  describe "while_preventing_writes" do
    it "blocks write operations within the block" do
      ConnectionTestModel.preventing_writes?.should be_false
      
      ConnectionTestModel.while_preventing_writes do
        ConnectionTestModel.preventing_writes?.should be_true
      end
      
      ConnectionTestModel.preventing_writes?.should be_false
    end
  end
  
  describe "adapter selection" do
    it "selects adapter based on current context" do
      # This test verifies the adapter method logic
      # In a real scenario, it would return different adapters
      ConnectionTestModel.adapter.should be_a(Grant::Adapter::Base)
    end
    
    it "falls back to registered connections when not configured" do
      # Models without connection configuration should still work
      # Should not raise error
      UnConfiguredModel.adapter.should be_a(Grant::Adapter::Base)
    end
  end
end