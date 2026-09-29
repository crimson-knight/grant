require "../../spec_helper"
require "file_utils"
require "../../support/simple_virtual_sharding"

# Regression specs for how connected_to contexts from different model classes
# interact in one fiber: raw write guards, shard routing for
# Grant::Sharding::Model, and stack restoration around connecting_to.
C01_SCOPE_DIR  = File.join(Dir.tempdir, "c01_scope_#{Process.pid}")
C01_SCOPE_ZERO = File.join(C01_SCOPE_DIR, "shard_0.sqlite3")
C01_SCOPE_ONE  = File.join(C01_SCOPE_DIR, "shard_1.sqlite3")

class C01ScopeSharded < Grant::Base
  connection c01_scope_sharded
  table c01_scope_sharded_rows

  include Grant::Sharding::Model

  shards_by :id, strategy: :hash, count: 2, prefix: "shard"

  column id : Int64, primary: true
  column label : String?
end

class C01ScopeOther < Grant::Base
  table c01_scope_others
  column id : Int64, primary: true
end

class C01ScopeUnverifiedOne < Grant::Base
  table c01_scope_unverified_ones
  column id : Int64, primary: true
  connects_to database: {writing: "c01_scope_missing_one"}
end

class C01ScopeUnverifiedTwo < Grant::Base
  table c01_scope_unverified_twos
  column id : Int64, primary: true
  connects_to database: :c01_scope_missing_two
end

describe "connected_to scoping across model classes" do
  before_all do
    Dir.mkdir_p(C01_SCOPE_DIR)
    {C01_SCOPE_ZERO => :shard_0, C01_SCOPE_ONE => :shard_1}.each do |path, shard|
      File.delete?(path)
      Grant::ConnectionRegistry.establish_connection(
        database: "c01_scope_sharded", adapter: Grant::Adapter::Sqlite,
        url: "sqlite3:#{path}", shard: shard)
    end
  end

  after_all do
    FileUtils.rm_rf(C01_SCOPE_DIR)
  end

  describe "Grant::Sharding::Model" do
    it "routes to the shard of a connected_to block on its own class" do
      C01ScopeSharded.connected_to(shard: :shard_1) { C01ScopeSharded.adapter.url }.should contain "shard_1.sqlite3"
      C01ScopeSharded.connected_to(shard: :shard_0) { C01ScopeSharded.adapter.url }.should contain "shard_0.sqlite3"
    end

    it "lets ShardManager.with_shard win over the connected_to shard" do
      C01ScopeSharded.connected_to(shard: :shard_1) do
        Grant::ShardManager.with_shard(:shard_0) { C01ScopeSharded.adapter.url }
      end.should contain "shard_0.sqlite3"
    end

    it "ignores a connected_to shard entered by an unrelated class" do
      C01ScopeOther.connected_to(shard: :shard_1) do
        Grant::ShardManager.current_shard.should be_nil
        expect_raises(Exception, /No shard context/) { C01ScopeSharded.adapter }
      end
    end
  end

  describe "raw connection write guard" do
    it "is not hidden by a later connected_to on an unrelated class" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.connected_to(role: :reading) do
          C01ScopeOther.connected_to(database: CURRENT_ADAPTER) do
            Grant.connection(CURRENT_ADAPTER).execute("DELETE FROM todos WHERE id = ?", [-1_i64])
          end
        end
      end
    end

    it "is lifted by an explicit writing role on the same class" do
      Todo.connected_to(role: :reading) do
        Todo.connected_to(role: :writing) do
          Grant::ConnectionManagement.preventing_writes?.should be_false
        end
        Grant::ConnectionManagement.preventing_writes?.should be_true
      end
      Grant::ConnectionManagement.preventing_writes?.should be_false
    end
  end

  describe "stack restoration" do
    it "keeps another class's context when reset_connecting_to runs inside a block" do
      C01ScopeOther.connected_to(role: :reading) do
        Todo.connected_to(shard: :x) do
          Todo.reset_connecting_to
        end
        C01ScopeOther.connected_to?(role: :reading).should be_true
      end
      C01ScopeOther.connection_context.should be_nil
    end

    it "leaves an enclosing connecting_to alone when reset runs inside another class's block" do
      Todo.connecting_to(role: :reading)
      begin
        C01ScopeOther.connected_to(shard: :x) do
          Todo.reset_connecting_to
          C01ScopeOther.current_shard.should eq :x
        end
        C01ScopeOther.connection_context.should be_nil
        Todo.connected_to?(role: :reading).should be_true
      ensure
        Todo.reset_connecting_to
      end
      Todo.connection_context.should be_nil
    end

    it "removes a connecting_to made inside a block when the block ends" do
      Todo.connected_to(role: :reading) do
        Todo.connecting_to(shard: :inner)
        Todo.current_shard.should eq :inner
      end
      Todo.connection_context.should be_nil
    end
  end

  describe "Grant::ConnectionHandling.verify_all!" do
    it "names every declaring model with missing connections in one error" do
      error = expect_raises(Grant::UnestablishedConnectionError) { Grant::ConnectionHandling.verify_all! }
      message = error.message.to_s
      message.should contain "C01ScopeUnverifiedOne declares connections that are not established: c01_scope_missing_one"
      message.should contain "C01ScopeUnverifiedTwo declares connections that are not established: c01_scope_missing_two"
    end
  end
end
