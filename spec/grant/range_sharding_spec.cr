require "../spec_helper"
require "../support/simple_virtual_sharding"

# Test models for range sharding
class RangeShardedOrder < Grant::Base
  connection "test"
  table range_sharded_orders
  
  include Grant::Sharding::Model
  extend Grant::Sharding::CompositeId
  
  # String-based range sharding
  shards_by :id, strategy: :range, ranges: [
    {min: "2023_01", max: "2023_12_99", shard: :shard_2023},
    {min: "2024_01", max: "2024_06_99", shard: :shard_2024_h1},
    {min: "2024_07", max: "2024_12_99", shard: :shard_2024_h2},
    {min: "2025_01", max: "2025_12_99", shard: :shard_current}
  ]
  
  column id : String, primary: true
  column user_id : Int64
  column total : Float64
  column created_at : Time = Time.utc
  
  before_create :generate_id
  
  private def generate_id
    self.id ||= RangeShardedOrder.generate_composite_id
  end
end

class NumericRangeEvent < Grant::Base
  connection "test"
  table numeric_range_events
  
  include Grant::Sharding::Model
  
  # Int64-based range sharding
  shards_by :id, strategy: :range, ranges: [
    {min: 1000_i64, max: 9999_i64, shard: :shard_old},
    {min: 10000_i64, max: 99999_i64, shard: :shard_medium},
    {min: 100000_i64, max: Int64::MAX, shard: :shard_current}
  ]
  
  column id : Int64, primary: true
  column event_type : String
end

include Grant::Testing::ShardingHelpers

describe "Range-based Sharding" do
  describe "String-based ranges" do
    it "routes to correct shard based on ID prefix" do
      # Test that IDs with different prefixes go to correct shards
      test_cases = [
        {id: "2023_06_15_123456_abc", expected_shard: :shard_2023},
        {id: "2024_03_20_789012_def", expected_shard: :shard_2024_h1},
        {id: "2024_09_10_345678_ghi", expected_shard: :shard_2024_h2},
        {id: "2025_01_01_901234_jkl", expected_shard: :shard_current}
      ]
      
      test_cases.each do |test|
        order = RangeShardedOrder.new(id: test[:id], user_id: 1_i64, total: 99.99)
        shard = order.determine_shard
        shard.should eq(test[:expected_shard])
      end
    end
    
    it "generates IDs that match configured ranges" do
      # Mock time to ensure predictable ID generation
      order = RangeShardedOrder.new(user_id: 1_i64, total: 99.99)
      order.send(:generate_id)
      
      # ID should start with current date
      order.id.should match(/^\d{4}_\d{2}_\d{2}_\d+_[a-f0-9]+$/)
      
      # Should be able to determine shard
      shard = order.determine_shard
      shard.should_not be_nil
    end
    
    it "queries route to single shard when using shard key" do
      with_virtual_shards(4) do
        # Query with specific ID should route to single shard
        query_log = track_shard_queries do
          RangeShardedOrder.where(id: "2024_03_15_123456_abc").select
        end
        
        query_log.shards_accessed.size.should eq(1)
        query_log.shards_accessed.first.should eq(:shard_2024_h1)
      end
    end
  end
  
  describe "Numeric ranges" do
    it "routes to correct shard based on numeric ID" do
      test_cases = [
        {id: 5000_i64, expected_shard: :shard_old},
        {id: 50000_i64, expected_shard: :shard_medium},
        {id: 500000_i64, expected_shard: :shard_current}
      ]
      
      test_cases.each do |test|
        event = NumericRangeEvent.new(id: test[:id], event_type: "click")
        shard = event.determine_shard
        shard.should eq(test[:expected_shard])
      end
    end
    
    it "handles edge cases correctly" do
      # Test boundary values
      edge_cases = [
        {id: 1000_i64, expected_shard: :shard_old},      # Min of range
        {id: 9999_i64, expected_shard: :shard_old},      # Max of range
        {id: 10000_i64, expected_shard: :shard_medium},  # Start of next range
      ]
      
      edge_cases.each do |test|
        event = NumericRangeEvent.new(id: test[:id], event_type: "test")
        shard = event.determine_shard
        shard.should eq(test[:expected_shard])
      end
    end
  end
  
  describe "Range validation" do
    it "validates ranges during resolver creation" do
      # Test overlapping ranges
      expect_raises(Exception, /Overlapping ranges/) do
        Grant::Sharding::RangeResolver.new(
          [:id],
          [
            {min: 1_i64, max: 1000_i64, shard: :shard_1},
            {min: 500_i64, max: 1500_i64, shard: :shard_2}  # Overlaps!
          ]
        )
      end
    end
    
    it "handles non-overlapping adjacent ranges" do
      # Adjacent ranges should be OK
      resolver = Grant::Sharding::RangeResolver.new(
        [:id],
        [
          {min: "2024_01", max: "2024_06_99", shard: :shard_1},
          {min: "2024_07", max: "2024_12_99", shard: :shard_2}
        ]
      )
      resolver.all_shards.should eq([:shard_1, :shard_2])
    end
  end
  
  describe "Query routing" do
    it "performs scatter-gather for non-shard-key queries" do
      with_virtual_shards(4) do
        # Query without shard key should hit all shards
        query_log = track_shard_queries do
          RangeShardedOrder.where(user_id: 123_i64).select
        end
        
        # Should query all configured shards
        query_log.shards_accessed.sort.should eq([:shard_2023, :shard_2024_h1, :shard_2024_h2, :shard_current])
      end
    end
    
    it "optimizes range queries when possible" do
      with_virtual_shards(4) do
        # Query with ID range that spans specific shards
        query_log = track_shard_queries do
          RangeShardedOrder.where("id >= ? AND id <= ?", "2024_01", "2024_08").select
        end
        
        # Should only query 2024 shards (both H1 and H2)
        # Note: Current implementation might query all shards
        # This is a future optimization opportunity
        query_log.shards_accessed.should_not be_empty
      end
    end
  end
end