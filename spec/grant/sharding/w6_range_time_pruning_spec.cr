require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../support/statement_recorder"
require "../../../src/grant/sharding"

# Three time-range shards, each a real database holding one row per month. A
# query that bounds the shard key visits only the shards its interval reaches,
# and the rows it returns come from those shards alone.
class W6TimeEvent < Grant::Base
  include Grant::Sharding::Model

  connection "w6_time"
  table w6_time_events
  column id : Int64, primary: true
  column created_at : Time
  column label : String?

  shards_by :created_at, strategy: :time_range, ranges: [
    {from: Time.utc(2024, 1, 1), to: Time.utc(2024, 7, 1), shard: :w6_h1},
    {from: Time.utc(2024, 7, 1), to: Time.utc(2025, 1, 1), shard: :w6_h2},
    {from: Time.utc(2025, 1, 1), to: Time.utc(2026, 1, 1), shard: :w6_current},
  ]
end

# Orders keyed by a generated, optionally prefixed, composite id.
class W6TimeOrder < Grant::Base
  include Grant::Sharding::Model

  connection "w6_time_orders"
  table w6_time_orders
  column id : String, primary: true
  column label : String?

  shards_by :id, strategy: :time_range, ranges: [
    {from: Time.utc(2024, 1, 1), to: Time.utc(2025, 1, 1), shard: :w6_o_2024},
    {from: Time.utc(2025, 1, 1), to: Time.utc(2026, 1, 1), shard: :w6_o_2025},
  ]
end

private module W6TimeIds
  extend Grant::Sharding::CompositeId

  # A composite id as `generate_composite_id` lays it out, for *time*.
  def self.id_at(time : Time, prefix : String? = nil, tail : String = "ab12cd34") : String
    milliseconds = time.to_unix_ms
    head = prefix ? "#{prefix}_" : ""
    "#{head}#{time.to_s("%Y_%m_%d")}_#{milliseconds.to_s.rjust(13, '0')}_#{tail}"
  end
end

private def w6_time_shards(builder : Grant::Query::Builder(W6TimeEvent)) : Array(Symbol)
  Grant::Sharding::QueryRouter(W6TimeEvent).new(W6TimeEvent, W6TimeEvent.sharding_config.not_nil!).shards_for(builder)
end

private def w6_labels(shard : Symbol, table : String = "w6_time_events") : Array(String)
  W6C04.strings("w6_time_#{shard}", "SELECT label FROM #{table} ORDER BY label")
end

describe "time-range shard pruning (#{CURRENT_ADAPTER})" do
  before_all do
    events_ddl = ["CREATE TABLE w6_time_events (#{W6C04.id_column}, created_at #{W6C04.pg? ? "TIMESTAMP" : "TEXT"} NOT NULL, label TEXT)"]
    {w6_h1:      [Time.utc(2024, 2, 10), Time.utc(2024, 6, 30, 23, 59, 59)],
     w6_h2:      [Time.utc(2024, 7, 1), Time.utc(2024, 12, 15)],
     w6_current: [Time.utc(2025, 1, 1), Time.utc(2025, 5, 5)]}.each do |shard, times|
      W6C04.provision("w6_time_#{shard}", events_ddl)
      W6C04.establish("w6_time", "w6_time_#{shard}", :primary, shard)
      times.each_with_index do |time, index|
        W6TimeEvent.new(created_at: time, label: "#{shard} #{index}").tap { |event| event.current_shard = shard }.save!(skip_timestamps: true)
      end
    end

    orders_ddl = ["CREATE TABLE w6_time_orders (id VARCHAR(80) PRIMARY KEY, label TEXT)"]
    {w6_o_2024: Time.utc(2024, 8, 1), w6_o_2025: Time.utc(2025, 3, 1)}.each do |shard, time|
      W6C04.provision("w6_time_#{shard}", orders_ddl)
      W6C04.establish("w6_time_orders", "w6_time_#{shard}", :primary, shard)
    end
  end

  after_all do
    {:w6_h1, :w6_h2, :w6_current}.each { |shard| W6C04.remove("w6_time", :primary, shard) }
    {:w6_o_2024, :w6_o_2025}.each { |shard| W6C04.remove("w6_time_orders", :primary, shard) }
    W6C04.cleanup
  end

  it "stores each event on the shard its created_at selects" do
    w6_labels(:w6_h1).should eq ["w6_h1 0", "w6_h1 1"]
    w6_labels(:w6_h2).should eq ["w6_h2 0", "w6_h2 1"]
    w6_labels(:w6_current).should eq ["w6_current 0", "w6_current 1"]
  end

  describe "a Time-typed where" do
    it "prunes an inclusive Range to the shards it reaches" do
      query = W6TimeEvent.where(created_at: Time.utc(2024, 2, 1)..Time.utc(2024, 3, 1))
      w6_time_shards(query).should eq [:w6_h1]
      query.select.map(&.label).should eq ["w6_h1 0"]

      w6_time_shards(W6TimeEvent.where(created_at: Time.utc(2024, 6, 1)..Time.utc(2024, 8, 1))).should eq [:w6_h1, :w6_h2]
    end

    it "visits only the pruned shards when it runs" do
      statements = StatementRecorder.statements do
        W6TimeEvent.where(created_at: Time.utc(2024, 8, 1)..Time.utc(2024, 9, 1)).select.should be_empty
      end
      statements.count(&.includes?("w6_time_events")).should eq 1
    end

    it "treats an exclusive end as exclusive at a shard boundary" do
      w6_time_shards(W6TimeEvent.where(created_at: Time.utc(2024, 1, 1)...Time.utc(2024, 7, 1))).should eq [:w6_h1]
      w6_time_shards(W6TimeEvent.where(created_at: Time.utc(2024, 1, 1)..Time.utc(2024, 7, 1))).should eq [:w6_h1, :w6_h2]
    end

    it "prunes a lower bound alone to the shard of the bound and every later one" do
      w6_time_shards(W6TimeEvent.where(created_at: Time.utc(2024, 8, 1)..)).should eq [:w6_h2, :w6_current]
      query = W6TimeEvent.where(created_at: Time.utc(2025, 3, 1)..)
      w6_time_shards(query).should eq [:w6_current]
      query.select.map(&.label).should eq ["w6_current 1"]
    end

    it "prunes an upper bound alone to the shard of the bound and every earlier one" do
      w6_time_shards(W6TimeEvent.where(created_at: ..Time.utc(2024, 3, 1))).should eq [:w6_h1]
      w6_time_shards(W6TimeEvent.where(created_at: ...Time.utc(2025, 1, 1))).should eq [:w6_h1, :w6_h2]
      w6_time_shards(W6TimeEvent.where(created_at: ..Time.utc(2025, 1, 1))).should eq [:w6_h1, :w6_h2, :w6_current]
    end

    it "prunes the comparison operators of where_chain" do
      w6_time_shards(W6TimeEvent.where(:created_at, :gteq, Time.utc(2025, 2, 1))).should eq [:w6_current]
      w6_time_shards(W6TimeEvent.where(:created_at, :lt, Time.utc(2024, 7, 1))).should eq [:w6_h1]
      w6_time_shards(W6TimeEvent.where(:created_at, :gt, Time.utc(2024, 3, 1)).where(:created_at, :lt, Time.utc(2024, 9, 1))).should eq [:w6_h1, :w6_h2]
    end

    it "intersects separate bounds on the key" do
      query = W6TimeEvent.where(:created_at, :gteq, Time.utc(2024, 8, 1)).where(:created_at, :lteq, Time.utc(2024, 9, 1))
      w6_time_shards(query).should eq [:w6_h2]
    end

    it "prunes a BETWEEN statement" do
      query = W6TimeEvent.where("created_at BETWEEN ? AND ?", Time.utc(2025, 2, 1), Time.utc(2025, 3, 1))
      w6_time_shards(query).should eq [:w6_current]
    end

    it "returns no rows, from no shard, for an interval outside every range" do
      query = W6TimeEvent.where(created_at: Time.utc(2010, 1, 1)..Time.utc(2011, 1, 1))
      w6_time_shards(query).should be_empty
      query.select.should be_empty
      query.count.should eq 0
    end

    it "keeps the whole result of a bound that spans every shard" do
      W6TimeEvent.where(created_at: Time.utc(2023, 1, 1)..Time.utc(2030, 1, 1)).select.size.should eq 6
    end

    it "scatter-gathers what it cannot prune" do
      all = [:w6_h1, :w6_h2, :w6_current]
      w6_time_shards(W6TimeEvent.where(label: "w6_h1 0")).should eq all
      w6_time_shards(W6TimeEvent.where(created_at: Time.utc(2024, 2, 1)..Time.utc(2024, 3, 1)).or(W6TimeEvent.where(label: "x"))).should eq all
      w6_time_shards(W6TimeEvent.where("created_at > now()")).should eq all
    end

    it "pins one shard for an equality on the key" do
      query = W6TimeEvent.where(created_at: Time.utc(2024, 7, 1))
      w6_time_shards(query).should eq [:w6_h2]
      query.select.map(&.label).should eq ["w6_h2 0"]
    end

    it "computes the shard set once for a count and an exists?" do
      W6TimeEvent.where(created_at: Time.utc(2024, 1, 1)...Time.utc(2024, 7, 1)).count.should eq 2
      W6TimeEvent.where(created_at: Time.utc(2025, 1, 1)..).exists?.should be_true
      W6TimeEvent.where(created_at: Time.utc(2024, 7, 1)...Time.utc(2025, 1, 1)).pluck(:label).map(&.to_s).sort.should eq ["w6_h2 0", "w6_h2 1"]
    end
  end

  describe "composite ids with a prefix" do
    it "routes a prefixed id like an unprefixed one" do
      resolver = W6TimeOrder.sharding_config.not_nil!.resolver
      plain = W6TimeIds.id_at(Time.utc(2025, 3, 1))
      prefixed = W6TimeIds.id_at(Time.utc(2025, 3, 1), "ORD")
      resolver.resolve_for_values([plain]).should eq :w6_o_2025
      resolver.resolve_for_values([prefixed]).should eq :w6_o_2025
      resolver.resolve_for_values([W6TimeIds.id_at(Time.utc(2024, 8, 1), "INVOICE9")]).should eq :w6_o_2024
    end

    it "routes ids from generate_composite_id with a prefix" do
      now = Time.utc
      resolver = Grant::Sharding::TimeRangeResolver.new([:id], [
        {from: now - 1.hour, to: now + 1.hour, shard: :recent},
        {from: now + 1.hour, to: now + 2.hours, shard: :future},
      ])
      resolver.resolve_for_values([W6TimeIds.generate_composite_id("ORD")]).should eq :recent
    end

    it "writes and finds a prefixed id on its shard" do
      id = W6TimeIds.id_at(Time.utc(2025, 3, 1), "ORD")
      W6TimeOrder.new(id: id, label: "prefixed").save!

      W6C04.strings("w6_time_w6_o_2025", "SELECT id FROM w6_time_orders").should eq [id]
      W6C04.strings("w6_time_w6_o_2024", "SELECT id FROM w6_time_orders").should be_empty
      W6TimeOrder.find!(id).label.should eq "prefixed"
    end

    it "prunes id bounds written with a prefix" do
      resolver = W6TimeOrder.sharding_config.not_nil!.resolver.as(Grant::Sharding::TimeRangeResolver)
      low = W6TimeIds.id_at(Time.utc(2025, 2, 1), "ORD")
      high = W6TimeIds.id_at(Time.utc(2025, 4, 1), "ORD")
      resolver.shards_for_bounds(low, high).should eq [:w6_o_2025]
      resolver.shards_for_bounds(low, nil).should eq [:w6_o_2025]
      resolver.shards_for_bounds(nil, W6TimeIds.id_at(Time.utc(2024, 9, 1), "ORD")).should eq [:w6_o_2024]
      resolver.shards_for_bounds("not-a-composite-id", nil).should be_nil
      resolver.shards_for_bounds(5_i64, nil).should be_nil
    end
  end

  describe "the range resolvers" do
    it "prunes Int64 and String bounds of a plain range resolver, open ended" do
      resolver = Grant::Sharding::RangeResolver.new([:id], [
        {min: 1_i64, max: 100_i64, shard: :low},
        {min: 101_i64, max: 200_i64, shard: :mid},
        {min: 201_i64, max: 300_i64, shard: :high},
      ])
      resolver.shards_for_bounds(150_i64, nil).should eq [:mid, :high]
      resolver.shards_for_bounds(nil, 150_i64).should eq [:low, :mid]
      resolver.shards_for_bounds(50_i64, 120_i64).should eq [:low, :mid]
      resolver.shards_for_bounds(Time.utc(2024, 1, 1), nil).should be_nil
      resolver.shards_for_bounds("a", nil).should be_nil
      resolver.shards_for_bounds(nil, nil).should be_nil
    end
  end
end
