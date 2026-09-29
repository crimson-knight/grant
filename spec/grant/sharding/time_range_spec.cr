require "../../spec_helper"
require "../../../src/grant/sharding"

private def build_resolver
  Grant::Sharding::TimeRangeResolver.new([:created_at], [
    {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 6, 30, 23, 59, 59), shard: :shard_2024_h1},
    {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 12, 31, 23, 59, 59), shard: :shard_2024_h2},
    {from: Time.utc(2025, 1, 1), to: Time.utc(2025, 12, 31, 23, 59, 59), shard: :shard_current},
  ])
end

class TimeRangeShardedEvent < Grant::Base
  connection "test"
  table time_range_sharded_events
  include Grant::Sharding::Model

  shards_by :created_at, strategy: :time_range, ranges: [
    {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 6, 30, 23, 59, 59), shard: :shard_2024_h1},
    {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 12, 31, 23, 59, 59), shard: :shard_2024_h2},
  ]

  column id : Int64, primary: true
  column created_at : Time
end

describe Grant::Sharding::TimeRangeResolver do
  it "resolves Time-typed shard keys" do
    resolver = build_resolver
    resolver.resolve_for_values([Time.utc(2024, 3, 15)]).should eq(:shard_2024_h1)
    resolver.resolve_for_values([Time.utc(2024, 7, 1)]).should eq(:shard_2024_h2)
    resolver.resolve_for_values([Time.utc(2025, 12, 31, 12)]).should eq(:shard_current)
  end

  it "includes both bounds and respects offsets as instants" do
    resolver = build_resolver
    resolver.resolve_for_values([Time.utc(2024, 1, 1)]).should eq(:shard_2024_h1)
    resolver.resolve_for_values([Time.utc(2024, 6, 30, 23, 59, 59)]).should eq(:shard_2024_h1)
    # 2024-07-01 01:00 +02:00 is 2024-06-30 23:00 UTC
    local = Time.local(2024, 7, 1, 1, 0, 0, location: Time::Location.fixed(2 * 3600))
    resolver.resolve_for_values([local]).should eq(:shard_2024_h1)
  end

  it "raises a Grant error for times outside every range" do
    expect_raises(Grant::Sharding::ShardNotFoundError) { build_resolver.resolve_for_values([Time.utc(2023, 5, 1)]) }
  end

  it "still resolves composite-ID string keys" do
    build_resolver.resolve_for_values(["2024_08_10_0001723_abcd"]).should eq(:shard_2024_h2)
  end

  it "lists shards once each in range order" do
    build_resolver.all_shards.should eq([:shard_2024_h1, :shard_2024_h2, :shard_current])
  end

  describe "range pruning" do
    it "returns only intersecting shards" do
      resolver = build_resolver
      resolver.shards_for_range(Time.utc(2024, 2, 1), Time.utc(2024, 3, 1)).should eq([:shard_2024_h1])
      resolver.shards_for_range(Time.utc(2024, 6, 1), Time.utc(2024, 8, 1)).should eq([:shard_2024_h1, :shard_2024_h2])
      resolver.shards_for_range(Time.utc(2025, 3, 1), Time.utc(2030, 1, 1)).should eq([:shard_current])
      resolver.shards_for_range(Time.utc(2010, 1, 1), Time.utc(2011, 1, 1)).should be_empty
    end

    it "prunes by a Time::Span back from now" do
      resolver = build_resolver
      now = Time.utc(2025, 2, 1)
      resolver.shards_for_last(30.days, now).should eq([:shard_current])
      resolver.shards_for_last(400.days, now).should eq([:shard_2024_h1, :shard_2024_h2, :shard_current])
    end
  end

  it "rejects overlapping and inverted ranges" do
    expect_raises(ArgumentError, /Overlapping/) do
      Grant::Sharding::TimeRangeResolver.new([:created_at], [
        {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 7, 1), shard: :a},
        {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 12, 1), shard: :b},
      ])
    end
    expect_raises(ArgumentError, /starts after/) do
      Grant::Sharding::TimeRangeResolver.new([:created_at], [
        {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 1, 1), shard: :a},
      ])
    end
  end

  it "is configured by shards_by strategy: :time_range" do
    resolver = TimeRangeShardedEvent.sharding_config.not_nil!.resolver
    resolver.resolve(TimeRangeShardedEvent.new(created_at: Time.utc(2024, 9, 9))).should eq(:shard_2024_h2)
  end
end
