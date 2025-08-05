require "../spec_helper"
require "../support/simple_virtual_sharding"

# Test models for geo sharding
class GeoShardedUser < Granite::Base
  connection "test"
  table geo_sharded_users
  
  include Granite::Sharding::Model
  include Granite::Sharding::RegionDetermination::ExplicitRegion
  
  shards_by [:country, :state], strategy: :geo,
    regions: [
      {
        shard: :shard_us_west,
        countries: ["US"],
        states: ["CA", "OR", "WA", "NV"]
      },
      {
        shard: :shard_us_east,
        countries: ["US"],
        states: ["NY", "NJ", "FL", "MA"]
      },
      {
        shard: :shard_us_central,
        countries: ["US"]  # Catch-all for other US states
      },
      {
        shard: :shard_eu,
        countries: ["GB", "DE", "FR", "IT", "ES"]
      },
      {
        shard: :shard_apac,
        countries: ["JP", "AU", "SG", "CN", "KR"]
      }
    ],
    default_shard: :shard_global
  
  column id : Int64, primary: true
  column email : String
  column country : String
  column state : String?
  column city : String?
end

class SimpleGeoModel < Granite::Base
  connection "test"
  table simple_geo_models
  
  include Granite::Sharding::Model
  
  # Simple country-only sharding
  shards_by :country, strategy: :geo,
    regions: [
      {shard: :shard_us, countries: ["US"]},
      {shard: :shard_eu, countries: ["GB", "DE", "FR"]},
      {shard: :shard_asia, countries: ["JP", "CN", "KR"]}
    ],
    default_shard: :shard_other
  
  column id : Int64, primary: true
  column country : String
  column data : String
end

include Granite::Testing::ShardingHelpers

describe "Geo-based Sharding" do
  describe "Country and state-based routing" do
    it "routes US states to correct regional shards" do
      test_cases = [
        {country: "US", state: "CA", expected: :shard_us_west},
        {country: "US", state: "OR", expected: :shard_us_west},
        {country: "US", state: "NY", expected: :shard_us_east},
        {country: "US", state: "FL", expected: :shard_us_east},
        {country: "US", state: "TX", expected: :shard_us_central},  # Not in west or east
        {country: "US", state: "IL", expected: :shard_us_central},  # Not in west or east
      ]
      
      test_cases.each do |test|
        user = GeoShardedUser.new(
          id: 1_i64,
          email: "test@example.com",
          country: test[:country],
          state: test[:state]
        )
        shard = user.determine_shard
        shard.should eq(test[:expected])
      end
    end
    
    it "routes non-US countries correctly" do
      test_cases = [
        {country: "GB", state: nil, expected: :shard_eu},
        {country: "DE", state: nil, expected: :shard_eu},
        {country: "JP", state: nil, expected: :shard_apac},
        {country: "AU", state: nil, expected: :shard_apac},
        {country: "BR", state: nil, expected: :shard_global},  # Not configured
        {country: "ZA", state: nil, expected: :shard_global},  # Default
      ]
      
      test_cases.each do |test|
        user = GeoShardedUser.new(
          id: 1_i64,
          email: "test@example.com",
          country: test[:country],
          state: test[:state]
        )
        shard = user.determine_shard
        shard.should eq(test[:expected])
      end
    end
  end
  
  describe "Country-only routing" do
    it "routes based on country alone" do
      test_cases = [
        {country: "US", expected: :shard_us},
        {country: "GB", expected: :shard_eu},
        {country: "FR", expected: :shard_eu},
        {country: "JP", expected: :shard_asia},
        {country: "BR", expected: :shard_other},  # Default
      ]
      
      test_cases.each do |test|
        model = SimpleGeoModel.new(
          id: 1_i64,
          country: test[:country],
          data: "test"
        )
        shard = model.determine_shard
        shard.should eq(test[:expected])
      end
    end
  end
  
  describe "Case insensitivity" do
    it "handles different case variations" do
      # Uppercase
      user1 = GeoShardedUser.new(id: 1_i64, email: "test@example.com", country: "US", state: "CA")
      # Lowercase
      user2 = GeoShardedUser.new(id: 2_i64, email: "test@example.com", country: "us", state: "ca")
      # Mixed case
      user3 = GeoShardedUser.new(id: 3_i64, email: "test@example.com", country: "Us", state: "Ca")
      
      user1.determine_shard.should eq(:shard_us_west)
      user2.determine_shard.should eq(:shard_us_west)
      user3.determine_shard.should eq(:shard_us_west)
    end
  end
  
  describe "Query routing" do
    it "routes queries with full shard key to single shard" do
      with_virtual_shards(5) do
        # Query with country and state should route to single shard
        query_log = track_shard_queries do
          GeoShardedUser.where(country: "US", state: "CA").select
        end
        
        query_log.shards_accessed.size.should eq(1)
        query_log.shards_accessed.first.should eq(:shard_us_west)
      end
    end
    
    it "routes queries with partial shard key to multiple shards" do
      with_virtual_shards(5) do
        # Query with only country might hit multiple US shards
        query_log = track_shard_queries do
          GeoShardedUser.where(country: "US").select
        end
        
        # Should hit all US shards (west, east, central)
        us_shards = [:shard_us_west, :shard_us_east, :shard_us_central]
        (query_log.shards_accessed & us_shards).should_not be_empty
      end
    end
    
    it "performs scatter-gather for non-shard-key queries" do
      with_virtual_shards(5) do
        # Query without geo information should hit all shards
        query_log = track_shard_queries do
          GeoShardedUser.where(email: "test@example.com").select
        end
        
        # Should query all shards including default
        query_log.shards_accessed.should_not be_empty
      end
    end
  end
  
  describe "Region validation" do
    it "validates required region fields are present" do
      user = GeoShardedUser.new(
        id: 1_i64,
        email: "test@example.com"
        # Missing country and state
      )
      
      user.valid?.should be_false
      user.errors[:country].should_not be_empty
    end
    
    it "allows nil state for non-US countries" do
      user = GeoShardedUser.new(
        id: 1_i64,
        email: "test@example.com",
        country: "GB"
        # State is nil, which is OK for UK
      )
      
      user.determine_shard.should eq(:shard_eu)
    end
  end
  
  describe "Region context" do
    it "can use region context for queries" do
      # Set region context (simulating middleware)
      Granite::Sharding::RegionDetermination::Context.with(country: "US", state: "CA") do
        # Context is available
        Granite::Sharding::RegionDetermination::Context.get(:country).should eq("US")
        Granite::Sharding::RegionDetermination::Context.get(:state).should eq("CA")
      end
      
      # Context is cleared after block
      Granite::Sharding::RegionDetermination::Context.get(:country).should be_nil
    end
  end
end