require "../../spec_helper"
require "../../../src/grant/sharding"

describe Grant::Sharding::HashResolver do
  it "accepts any count from 1 through the table size" do
    [1, 2, 3, 5, 6, 7, 9, 10, 12, 100, 255, 256].each do |count|
      resolver = Grant::Sharding::HashResolver.new([:id], count)
      resolver.all_shards.size.should eq(count)
      resolver.all_shards.first.should eq(:shard_0)
      resolver.all_shards.last.should eq(Grant::Sharding::HashResolver::SHARD_NAMES[count - 1])
    end
  end

  it "only routes to declared shards and spreads keys across them" do
    resolver = Grant::Sharding::HashResolver.new([:id], 10)
    seen = Set(Symbol).new
    (1_i64..2000_i64).each do |id|
      shard = resolver.resolve_for_values([id])
      resolver.all_shards.should contain(shard)
      seen << shard
    end
    seen.size.should eq(10)
  end

  it "rejects zero, negative, and oversized counts with a Grant error" do
    [0, -1, 257].each do |count|
      expect_raises(Grant::Sharding::UnsupportedShardCountError, /Unsupported shard count/) do
        Grant::Sharding::HashResolver.new([:id], count)
      end
    end
  end

  it "accepts explicitly named shards" do
    resolver = Grant::Sharding::HashResolver.new([:id], [:alpha, :beta])
    resolver.shard_count.should eq(2)
    resolver.all_shards.should eq([:alpha, :beta])
    resolver.resolve_for_values([1_i64]).should eq(:alpha)
    resolver.resolve_for_values([42_i64]).should eq(:beta)
  end

  it "rejects empty and duplicate explicit shard lists" do
    expect_raises(Grant::Sharding::UnsupportedShardCountError) { Grant::Sharding::HashResolver.new([:id], [] of Symbol) }
    expect_raises(Grant::Sharding::UnsupportedShardCountError) { Grant::Sharding::HashResolver.new([:id], [:a, :a]) }
  end
end

class ShardCountModel < Grant::Base
  connection "test"
  table shard_count_models
  include Grant::Sharding::Model

  shards_by :id, strategy: :hash, count: 12
  column id : Int64, primary: true
end

class ShardNamesModel < Grant::Base
  connection "test"
  table shard_names_models
  include Grant::Sharding::Model

  shards_by :id, strategy: :hash, shards: [:east, :west]
  column id : Int64, primary: true
end

describe "shards_by hash options" do
  it "builds any count from count:" do
    ShardCountModel.sharding_config.not_nil!.resolver.all_shards.size.should eq(12)
  end

  it "builds named shards from shards:" do
    ShardNamesModel.sharding_config.not_nil!.resolver.all_shards.should eq([:east, :west])
  end
end
