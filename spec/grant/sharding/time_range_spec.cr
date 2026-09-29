require "../../spec_helper"
require "../../../src/grant/sharding"

private def build_resolver
  Grant::Sharding::TimeRangeResolver.new([:created_at], [
    {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 7, 1), shard: :shard_2024_h1},
    {from: Time.utc(2024, 7, 1), to: Time.utc(2025, 1, 1), shard: :shard_2024_h2},
    {from: Time.utc(2025, 1, 1), to: Time.utc(2026, 1, 1), shard: :shard_current},
  ])
end

private class TimeRangeCompositeIdGenerator
  extend Grant::Sharding::CompositeId
end

class TimeRangeShardedEvent < Grant::Base
  connection "test"
  table time_range_sharded_events
  include Grant::Sharding::Model

  shards_by :created_at, strategy: :time_range, ranges: [
    {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 7, 1), shard: :shard_2024_h1},
    {from: Time.utc(2024, 7, 1), to: Time.utc(2025, 1, 1), shard: :shard_2024_h2},
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

  it "includes from, excludes to, and respects offsets as instants" do
    resolver = build_resolver
    resolver.resolve_for_values([Time.utc(2024, 1, 1)]).should eq(:shard_2024_h1)
    resolver.resolve_for_values([Time.utc(2024, 6, 30, 23, 59, 59, nanosecond: 999_999_999)]).should eq(:shard_2024_h1)
    resolver.resolve_for_values([Time.utc(2024, 7, 1)]).should eq(:shard_2024_h2)
    # 2024-07-01 01:00 +02:00 is 2024-06-30 23:00 UTC
    local = Time.local(2024, 7, 1, 1, 0, 0, location: Time::Location.fixed(2 * 3600))
    resolver.resolve_for_values([local]).should eq(:shard_2024_h1)
  end

  it "raises a Grant error for times outside every range" do
    expect_raises(Grant::Sharding::ShardNotFoundError) { build_resolver.resolve_for_values([Time.utc(2023, 5, 1)]) }
  end

  it "resolves composite-ID string keys by the millisecond they carry" do
    resolver = build_resolver
    boundary = Time.utc(2024, 7, 1).to_unix_ms
    resolver.resolve_for_values(["2024_06_30_#{(boundary - 1).to_s.rjust(13, '0')}_abcd1234"]).should eq(:shard_2024_h1)
    resolver.resolve_for_values(["2024_07_01_#{boundary.to_s.rjust(13, '0')}_abcd1234"]).should eq(:shard_2024_h2)
  end

  it "routes ids from CompositeId#generate_composite_id" do
    now = Time.utc
    resolver = Grant::Sharding::TimeRangeResolver.new([:id], [
      {from: now - 1.hour, to: now + 1.hour, shard: :recent},
      {from: now + 1.hour, to: now + 2.hours, shard: :future},
    ])
    resolver.resolve_for_values([TimeRangeCompositeIdGenerator.generate_composite_id]).should eq(:recent)
  end

  it "does not resolve keys it cannot compare" do
    resolver = build_resolver
    expect_raises(Grant::Sharding::ShardKeyMissingError) { resolver.resolve_for_values([nil]) }
    expect_raises(Grant::Sharding::ShardKeyMissingError) { resolver.resolve_for_values([] of Time) }
    expect_raises(Grant::Sharding::ShardNotFoundError) { resolver.resolve_for_values([42_i64]) }
    expect_raises(Grant::Sharding::ShardNotFoundError) { resolver.resolve_for_values(["2024-03-01"]) }
  end

  it "accepts sub-day ranges" do
    resolver = Grant::Sharding::TimeRangeResolver.new([:created_at], [
      {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 1, 1, 12), shard: :morning},
      {from: Time.utc(2024, 1, 1, 12), to: Time.utc(2024, 1, 2), shard: :afternoon},
    ])
    resolver.resolve_for_values([Time.utc(2024, 1, 1, 11, 59, 59, nanosecond: 500_000_000)]).should eq(:morning)
    resolver.resolve_for_values([Time.utc(2024, 1, 1, 12)]).should eq(:afternoon)
    noon = Time.utc(2024, 1, 1, 12).to_unix_ms
    resolver.resolve_for_values(["2024_01_01_#{(noon - 1).to_s.rjust(13, '0')}_ff"]).should eq(:morning)
    resolver.resolve_for_values(["2024_01_01_#{noon.to_s.rjust(13, '0')}_00"]).should eq(:afternoon)
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
      resolver.shards_for_range(Time.utc(2024, 7, 1), Time.utc(2024, 7, 1)).should eq([:shard_2024_h2])
    end

    it "declines to prune bounds it cannot compare, so callers scatter-gather" do
      resolver = build_resolver
      resolver.shards_for_range("2024-02-01", "2024-03-01").should be_nil
      resolver.shards_for_range(1_i64, 2_i64).should be_nil
      low = "2024_02_01_#{Time.utc(2024, 2, 1).to_unix_ms.to_s.rjust(13, '0')}"
      high = "2024_03_01_#{Time.utc(2024, 3, 1).to_unix_ms.to_s.rjust(13, '0')}"
      resolver.shards_for_range(low, high).should eq([:shard_2024_h1])
    end

    it "prunes by a Time::Span back from now" do
      resolver = build_resolver
      now = Time.utc(2025, 2, 1)
      resolver.shards_for_last(30.days, now).should eq([:shard_current])
      resolver.shards_for_last(400.days, now).should eq([:shard_2024_h1, :shard_2024_h2, :shard_current])
    end
  end

  it "rejects overlapping, empty, and inverted ranges" do
    expect_raises(ArgumentError, /Overlapping/) do
      Grant::Sharding::TimeRangeResolver.new([:created_at], [
        {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 7, 2), shard: :a},
        {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 12, 1), shard: :b},
      ])
    end
    expect_raises(ArgumentError, /must start before/) do
      Grant::Sharding::TimeRangeResolver.new([:created_at], [
        {from: Time.utc(2024, 7, 1), to: Time.utc(2024, 7, 1), shard: :a},
      ])
    end
    expect_raises(ArgumentError, /must start before/) do
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
