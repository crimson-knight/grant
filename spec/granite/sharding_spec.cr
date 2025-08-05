require "../spec_helper"
require "../support/simple_virtual_sharding"

# Set up a test connection for sharding tests
Granite::Connections << Granite::Adapter::Sqlite.new(name: "test", url: "sqlite::memory:")

# Test model for sharding
class ShardedUser < Granite::Base
  # Set up test connection
  connection "test"
  table sharded_users
  
  include Granite::Sharding::Model
  
  # Configure hash sharding on ID
  shards_by :id, strategy: :hash, count: 4, prefix: "shard"
  
  column id : Int64, primary: true
  column name : String
  column email : String
  column active : Bool = true
  column region : String?
  column created_at : Time = Time.utc
end

include Granite::Testing::ShardingHelpers

describe "Granite::Sharding" do
  
  describe "ShardManager" do
    it "registers shard configuration" do
      config = Granite::ShardManager.shard_config("ShardedUser")
      config.should_not be_nil
      config.not_nil!.key_columns.should eq([:id])
    end
    
    it "resolves shard for given keys" do
      shard = Granite::ShardManager.resolve_shard("ShardedUser", id: 123_i64)
      shard.to_s.should match(/^shard_\d$/)
    end
    
    it "returns all shards for a model" do
      shards = Granite::ShardManager.shards_for_model("ShardedUser")
      shards.size.should eq(4)
      shards.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
    end
    
    it "tracks current shard per fiber" do
      Granite::ShardManager.current_shard.should be_nil
      
      Granite::ShardManager.with_shard(:test_shard) do
        Granite::ShardManager.current_shard.should eq(:test_shard)
      end
      
      Granite::ShardManager.current_shard.should be_nil
    end
  end
  
  describe "Hash Sharding" do
    it "distributes records across shards based on ID" do
      with_virtual_shards(4) do
        # Test that different IDs go to different shards
        shards_used = Set(Symbol).new
        
        10.times do |i|
          id = (i + 1).to_i64
          shard = Granite::ShardManager.resolve_shard("ShardedUser", id: id)
          shards_used << shard
        end
        
        # Should use multiple shards (very likely all 4 with 10 IDs)
        shards_used.size.should be >= 2
      end
    end
    
    it "consistently routes to the same shard for the same ID" do
      with_virtual_shards(4) do
        id = 12345_i64
        shard1 = Granite::ShardManager.resolve_shard("ShardedUser", id: id)
        shard2 = Granite::ShardManager.resolve_shard("ShardedUser", id: id)
        
        shard1.should eq(shard2)
      end
    end
  end
  
  describe "Query Routing" do
    it "routes queries with shard key to single shard" do
      with_virtual_shards(4) do
        # Determine which shard ID 123 should go to
        user_id = 123_i64
        expected_shard = Granite::ShardManager.resolve_shard("ShardedUser", id: user_id)
        
        # Query should only hit the expected shard
        query_log = track_shard_queries do
          ShardedUser.where(id: user_id).select
        end
        
        query_log.shards_accessed.should eq([expected_shard])
      end
    end
    
    pending "performs scatter-gather for queries without shard key" do
      with_virtual_shards(4) do
        # Query without shard key should hit all shards
        query_log = track_shard_queries do
          ShardedUser.where(active: true).select
        end
        
        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end
    
    pending "routes count queries correctly" do
      with_virtual_shards(4) do
        # Count should aggregate across all shards
        # For now, just verify it attempts to query all shards
        query_log = track_shard_queries do
          ShardedUser.count
        end
        
        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end
  end
  
  describe "on_shard scope" do
    it "forces queries to specific shard" do
      with_virtual_shards(4) do
        query_log = track_shard_queries do
          ShardedUser.on_shard(:shard_2).where(active: true).select
        end
        
        query_log.shards_accessed.should eq([:shard_2])
      end
    end
  end
  
  describe "on_all_shards scope" do
    pending "executes queries on all shards" do
      with_virtual_shards(4) do
        query_log = track_shard_queries do
          ShardedUser.on_all_shards.count
        end
        
        query_log.shards_accessed.sort.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
      end
    end
  end
  
  describe "Model integration" do
    it "determines shard before save" do
      with_virtual_shards(4) do
        user = ShardedUser.new(
          id: 456_i64,
          name: "Test User",
          email: "test@example.com",
          active: true,
          created_at: Time.utc
        )
        
        user.current_shard.should be_nil
        shard = user.determine_shard
        shard.should_not be_nil
        shard.should eq(Granite::ShardManager.resolve_shard("ShardedUser", id: 456_i64))
      end
    end
  end
end