require "../../spec_helper"
require "../../support/real_sqlite_shards"

class W6shThing < Grant::Base
  connection "w6sh_routing"
  table w6sh_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?
end

W6SH_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "w6sh_routing", [:one, :two],
  ["CREATE TABLE w6sh_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT)"]
)

private def sharded_order : Grant::Sharding::ShardedQueryBuilder(W6shThing)
  W6shThing.order(id: :asc).as(Grant::Sharding::ShardedQueryBuilder(W6shThing))
end

describe "ShardedQueryBuilder#on_shard is a chain method" do
  before_all do
    W6SH_FIXTURE.set_up
    (1_i64..6_i64).each do |id|
      shard = id.odd? ? :one : :two
      W6SH_FIXTURE.exec(shard, "INSERT INTO w6sh_things (id, tenant_id, label) VALUES (?, ?, ?)", id, id.odd? ? 1_i64 : 2_i64, "row #{id}")
    end
  end

  after_all { W6SH_FIXTURE.tear_down }

  it "returns a copy pinned to the shard and leaves the receiver alone" do
    base = sharded_order
    pinned = base.on_shard(:one)

    pinned.should_not be(base)
    pinned.select.map(&.id).should eq([1_i64, 3_i64, 5_i64])
    base.select.map(&.id).should eq((1_i64..6_i64).to_a)
  end

  it "lets two pins of one relation target different shards" do
    base = sharded_order
    one = base.on_shard(:one)
    two = base.on_shard(:two)
    one.select.map(&.id).should eq([1_i64, 3_i64, 5_i64])
    two.select.map(&.id).should eq([2_i64, 4_i64, 6_i64])
  end

  it "on_all_shards does not change the receiver either" do
    pinned = sharded_order.on_shard(:one)
    everywhere = pinned.on_all_shards
    everywhere.select.map(&.id).should eq((1_i64..6_i64).to_a)
    pinned.select.map(&.id).should eq([1_i64, 3_i64, 5_i64])
  end

  it "the bang forms pin in place" do
    relation = sharded_order.on_shard(:two)
    relation.on_shard!(:one).should be(relation)
    relation.select.map(&.id).should eq([1_i64, 3_i64, 5_i64])
    relation.on_all_shards!.select.map(&.id).should eq((1_i64..6_i64).to_a)
  end
end
