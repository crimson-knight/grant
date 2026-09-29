require "../../spec_helper"
require "../../../src/grant/sharding"

class LookupShardedAccount < Grant::Base
  connection "test"
  table lookup_sharded_accounts
  include Grant::Sharding::Model

  shards_by :country, strategy: :lookup,
    lookup: {"US" => :shard_us, "CA" => :shard_us, "DE" => :shard_eu},
    default_shard: :shard_global

  column id : Int64, primary: true
  column country : String
end

describe Grant::Sharding::LookupResolver do
  it "is configured by shards_by strategy: :lookup" do
    resolver = LookupShardedAccount.sharding_config.not_nil!.resolver
    resolver.should be_a(Grant::Sharding::LookupResolver)
    resolver.resolve_for_values(["US"]).should eq(:shard_us)
    resolver.resolve_for_values(["DE"]).should eq(:shard_eu)
  end

  it "uses default_shard for unlisted values" do
    resolver = LookupShardedAccount.sharding_config.not_nil!.resolver
    resolver.resolve_for_values(["JP"]).should eq(:shard_global)
    resolver.resolve_for_keys(country: "JP").should eq(:shard_global)
  end

  it "resolves a model instance" do
    LookupShardedAccount.sharding_config.not_nil!.resolver.resolve(LookupShardedAccount.new(country: "CA")).should eq(:shard_us)
  end

  it "raises a Grant error without a default" do
    resolver = Grant::Sharding::LookupResolver.new(:country, {"US" => :shard_us})
    expect_raises(Grant::Sharding::ShardNotFoundError, /JP/) { resolver.resolve_for_values(["JP"]) }
    expect_raises(Grant::Sharding::ShardKeyMissingError) { resolver.resolve_for_values([] of String) }
    expect_raises(Grant::Sharding::ShardKeyMissingError) { resolver.resolve_for_keys(other: 1) }
  end

  it "lists each shard once in all_shards" do
    LookupShardedAccount.sharding_config.not_nil!.resolver.all_shards.should eq([:shard_us, :shard_eu, :shard_global])
  end

  it "does not duplicate a default_shard already present in the table" do
    resolver = Grant::Sharding::LookupResolver.new(:country, {"US" => :shard_us, "DE" => :shard_eu}, :shard_eu)
    resolver.all_shards.should eq([:shard_us, :shard_eu])
  end

  it "does not scatter to a shard twice through ShardManager" do
    Grant::ShardManager.shards_for_model("LookupShardedAccount").should eq([:shard_us, :shard_eu, :shard_global])
    Grant::ShardManager.register("LookupDupDefault", Grant::Sharding::ShardConfig.new([:country],
      Grant::Sharding::LookupResolver.new(:country, {"US" => :shard_us}, :shard_us)))
    Grant::ShardManager.shards_for_model("LookupDupDefault").should eq([:shard_us])
  end
end
