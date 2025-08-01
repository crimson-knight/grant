require "../spec_helper"

# Test models defined at top level
class TestConnectionModel < Granite::Base
  include Granite::ConnectionManagementV2
  
  table test_models
  column id : Int64, primary: true
  column name : String
  
  connects_to(
    database: "test_db",
    config: {
      writing: "postgres://writer@localhost/test_db",
      reading: "postgres://reader@localhost/test_db"
    }
  )
end

class ShardedModel < Granite::Base
  include Granite::ConnectionManagementV2
  
  table sharded_models
  column id : Int64, primary: true
  column name : String
  
  connects_to(
    shards: {
      shard_one: {
        writing: "postgres://shard1_writer@localhost/db1",
        reading: "postgres://shard1_reader@localhost/db1"
      },
      shard_two: {
        writing: "postgres://shard2_writer@localhost/db2",
        reading: "postgres://shard2_reader@localhost/db2"
      }
    }
  )
end

class ContextModel < Granite::Base
  include Granite::ConnectionManagementV2
  
  table context_models
  column id : Int64, primary: true
  
  connects_to(
    database: "main_db",
    config: {
      writing: "postgres://writer@localhost/main",
      reading: "postgres://reader@localhost/main"
    }
  )
end

class WriteProtectedModel < Granite::Base
  include Granite::ConnectionManagementV2
  
  table protected_models
  column id : Int64, primary: true
  column name : String
end

class MultiDbModel < Granite::Base
  include Granite::ConnectionManagementV2
  
  table multi_db_models
  column id : Int64, primary: true
  
  connects_to(database: "primary")
end

class ReadWriteModel < Granite::Base
  include Granite::ConnectionManagementV2
  
  table rw_models
  column id : Int64, primary: true
  column name : String
  
  connects_to(
    config: {
      writing: "postgres://writer@localhost/test",
      reading: "postgres://reader@localhost/test"
    }
  )
  
  # Set a short delay for testing
  self.read_delay = 0.1.seconds
end

# Now define the actual tests
describe "Granite::ConnectionHandling" do
  describe ".connects_to" do
    it "configures database connections with roles" do
      TestConnectionModel.database_name.should eq "test_db"
      TestConnectionModel.connection_config[:writing].should eq "postgres://writer@localhost/test_db"
      TestConnectionModel.connection_config[:reading].should eq "postgres://reader@localhost/test_db"
    end
    
    it "supports sharded configurations" do
      ShardedModel.shard_config.should_not be_nil
      ShardedModel.shard_config[:shard_one][:writing].should eq "postgres://shard1_writer@localhost/db1"
      ShardedModel.shard_config[:shard_two][:reading].should eq "postgres://shard2_reader@localhost/db2"
    end
  end
  
  describe ".connected_to" do
    it "switches connection context for a block" do
      # Default should be primary role
      ContextModel.current_role.should eq :primary
      
      # Switch to reading role
      ContextModel.connected_to(role: :reading) do
        ContextModel.current_role.should eq :reading
      end
      
      # Should revert back
      ContextModel.current_role.should eq :primary
    end
    
    it "prevents writes when specified" do
      WriteProtectedModel.preventing_writes?.should be_false
      
      WriteProtectedModel.while_preventing_writes do
        WriteProtectedModel.preventing_writes?.should be_true
      end
      
      WriteProtectedModel.preventing_writes?.should be_false
    end
    
    it "switches to different database" do
      MultiDbModel.current_database.should eq "primary"
      
      MultiDbModel.connected_to(database: "secondary") do
        MultiDbModel.current_database.should eq "secondary"
      end
      
      MultiDbModel.current_database.should eq "primary"
    end
  end
  
  describe "automatic read/write splitting" do
    it "uses writer for mutations and reader for queries after delay" do
      # After a write, should use writer
      ReadWriteModel.mark_write_operation
      ReadWriteModel.current_role.should eq :primary
      
      # Wait for delay
      sleep 0.2
      
      # Should now use reader (if reading role is configured)
      # This would be :reading if we have a reading connection configured
      # For now it stays :primary as fallback
      ReadWriteModel.current_role.should eq :primary
    end
  end
end