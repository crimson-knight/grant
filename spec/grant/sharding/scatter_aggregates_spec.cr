require "../../spec_helper"
require "../../support/real_sqlite_shards"

# Shard one holds amounts 10, 20, 30 (mean 20). Shard two holds 5 and 100 and
# one NULL (mean 52.5). The mean of all five amounts is 33.0; averaging the two
# shard means would give 36.25, so a wrong merge cannot pass.
class S02AggregateOrder < Grant::Base
  connection "s02_aggregates"
  table s02_aggregate_orders
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column category : String
  column amount : Int64?
  column price : Float64?
end

S02_AGGREGATE_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_aggregates", [:one, :two],
  ["CREATE TABLE s02_aggregate_orders (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, category TEXT NOT NULL, amount INTEGER, price REAL)"]
)

describe "Scatter-gather aggregates on sharded models" do
  before_all do
    S02_AGGREGATE_FIXTURE.set_up
    insert = "INSERT INTO s02_aggregate_orders (tenant_id, category, amount, price) VALUES (?, ?, ?, ?)"
    S02_AGGREGATE_FIXTURE.exec(:one, insert, 1_i64, "a", 10_i64, 1.5)
    S02_AGGREGATE_FIXTURE.exec(:one, insert, 1_i64, "a", 20_i64, 2.5)
    S02_AGGREGATE_FIXTURE.exec(:one, insert, 1_i64, "b", 30_i64, 3.0)
    S02_AGGREGATE_FIXTURE.exec(:two, insert, 2_i64, "a", 5_i64, 0.25)
    S02_AGGREGATE_FIXTURE.exec(:two, insert, 2_i64, "b", 100_i64, 10.0)
    S02_AGGREGATE_FIXTURE.exec(:two, insert, 2_i64, "b", nil, nil)
  end

  after_all do
    S02_AGGREGATE_FIXTURE.tear_down
  end

  it "sums the per-shard sums" do
    S02AggregateOrder.sum(:amount).should eq 165_i64
    S02AggregateOrder.where(tenant_id: 1_i64).sum(:amount).should eq 60_i64
    S02AggregateOrder.where(tenant_id: 2_i64).sum(:amount).should eq 105_i64
  end

  it "sums float columns" do
    S02AggregateOrder.sum(:price).should eq 17.25
  end

  it "sums as an exact type" do
    S02AggregateOrder.order(id: :asc).sum(:amount, as: Int64).should eq 165_i64
  end

  it "takes the minimum of the per-shard minimums" do
    S02AggregateOrder.min(:amount).should eq 5_i64
    S02AggregateOrder.minimum(:amount).should eq 5_i64
    S02AggregateOrder.where(tenant_id: 1_i64).min(:amount).should eq 10_i64
  end

  it "takes the maximum of the per-shard maximums" do
    S02AggregateOrder.max(:amount).should eq 100_i64
    S02AggregateOrder.maximum(:amount).should eq 100_i64
    S02AggregateOrder.where(tenant_id: 1_i64).max(:amount).should eq 30_i64
  end

  it "computes the average from the summed sums and counts, not from the shard averages" do
    S02AggregateOrder.average(:amount).should eq 33.0
    S02AggregateOrder.avg(:amount).should eq 33.0
    S02AggregateOrder.where(tenant_id: 2_i64).average(:amount).should eq 52.5
  end

  it "answers calculate for every operation" do
    S02AggregateOrder.calculate(:sum, :amount).should eq 165_i64
    S02AggregateOrder.calculate(:average, :amount).should eq 33.0
    S02AggregateOrder.calculate(:minimum, :amount).should eq 5_i64
    S02AggregateOrder.calculate(:maximum, :amount).should eq 100_i64
    S02AggregateOrder.calculate(:count).should eq 6_i64
    S02AggregateOrder.calculate(:count, :amount).should eq 5_i64
  end

  it "counts a column across shards, skipping NULL" do
    S02AggregateOrder.all.count(:amount).should eq 5_i64
    S02AggregateOrder.all.count(:all).should eq 6_i64
  end

  it "returns zero, nil and nil for an empty relation" do
    empty = S02AggregateOrder.where("amount > ?", 1000_i64)
    empty.sum(:amount).should eq 0_i64
    empty.average(:amount).should be_nil
    empty.min(:amount).should be_nil
    empty.max(:amount).should be_nil
  end

  it "merges grouped aggregates by key" do
    S02AggregateOrder.group_by(:category).sum(:amount).should eq({"a" => 35_i64, "b" => 130_i64})
    S02AggregateOrder.group_by(:category).min(:amount).should eq({"a" => 5_i64, "b" => 30_i64})
    S02AggregateOrder.group_by(:category).max(:amount).should eq({"a" => 20_i64, "b" => 100_i64})
    S02AggregateOrder.group_by(:category).count.should eq({"a" => 3_i64, "b" => 3_i64})

    averages = S02AggregateOrder.group_by(:category).average(:amount)
    averages.as(Hash(Grant::Columns::Type, Float64?))["a"].not_nil!.should be_close(35.0 / 3, 0.0001)
    averages.as(Hash(Grant::Columns::Type, Float64?))["b"].should eq 65.0
  end

  it "refuses a DISTINCT or LIMITed aggregate that spans shards" do
    expect_raises(Grant::Sharding::ScatterAggregateError, /DISTINCT/) do
      S02AggregateOrder.distinct.sum(:amount)
    end
    expect_raises(Grant::Sharding::ScatterAggregateError, /LIMIT/) do
      S02AggregateOrder.limit(2).sum(:amount)
    end
  end

  it "lets a DISTINCT aggregate through when it targets one shard" do
    S02AggregateOrder.where(tenant_id: 1_i64).distinct.sum(:amount).should eq 60_i64
  end

  it "runs inside a fixed shard when one is active" do
    Grant::ShardManager.with_shard(:two) { S02AggregateOrder.sum(:amount) }.should eq 105_i64
    S02AggregateOrder.connected_to(shard: :one) { S02AggregateOrder.max(:amount) }.should eq 30_i64
  end
end
