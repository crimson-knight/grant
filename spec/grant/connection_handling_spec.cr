require "../spec_helper"

# Test models defined at top level
class TestConnectionModel < Grant::Base
  table test_models
  column id : Int64, primary: true
  column name : String

  connects_to(
    database: "test_db",
    config: {
      writing: "postgres://writer@localhost/test_db",
      reading: "postgres://reader@localhost/test_db",
    }
  )
end

class ShardedModel < Grant::Base
  table sharded_models
  column id : Int64, primary: true
  column name : String

  connects_to(
    shards: {
      shard_one: {
        writing: "postgres://shard1_writer@localhost/db1",
        reading: "postgres://shard1_reader@localhost/db1",
      },
      shard_two: {
        writing: "postgres://shard2_writer@localhost/db2",
        reading: "postgres://shard2_reader@localhost/db2",
      },
    }
  )
end

class ContextModel < Grant::Base
  table context_models
  column id : Int64, primary: true

  connects_to(
    database: "main_db",
    config: {
      writing: "postgres://writer@localhost/main",
      reading: "postgres://reader@localhost/main",
    }
  )
end

class WriteProtectedModel < Grant::Base
  table protected_models
  column id : Int64, primary: true
  column name : String
end

class MultiDbModel < Grant::Base
  table multi_db_models
  column id : Int64, primary: true

  connects_to(database: "primary")
end

class ReadWriteModel < Grant::Base
  table rw_models
  column id : Int64, primary: true
  column name : String

  connects_to(
    config: {
      writing: "postgres://writer@localhost/test",
      reading: "postgres://reader@localhost/test",
    }
  )
end

# Now define the actual tests
describe "Grant::ConnectionHandling" do
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
      # With no recent writes, automatic read/write splitting selects the
      # reader. The temporary context should still be isolated and restored.
      ContextModel.connection_context.should be_nil
      ContextModel.current_role.should eq :reading

      # Switch to reading role
      ContextModel.connected_to(role: :reading) do
        ContextModel.current_role.should eq :reading
        ContextModel.connection_context.not_nil!.role.should eq :reading
      end

      ContextModel.connection_context.should be_nil
      ContextModel.current_role.should eq :reading
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
    it "uses the reader for queries after the post-write delay" do
      original_wait_period = Grant::Connections.connection_switch_wait_period
      ReadWriteModel.connection_switch_wait_period = 100

      begin
        # After a write, should use writer
        ReadWriteModel.mark_write_operation
        ReadWriteModel.current_role.should eq :primary

        # Wait for delay
        sleep(0.2.seconds)

        # The model has a reading role configured, so reads may use it after the
        # quiet period has elapsed.
        ReadWriteModel.current_role.should eq :reading
      ensure
        ReadWriteModel.connection_switch_wait_period = original_wait_period
      end
    end
  end
end
