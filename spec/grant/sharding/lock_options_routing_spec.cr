require "../../spec_helper"
require "../../support/real_sqlite_shards"

# Every pessimistic-lock entry point on a sharded record (the force:,
# requires_new: and custom-clause forms included) must run on the shard the
# record lives on, not only the default-argument forms.
class W3LockRoutingThing < Grant::Base
  connection "w3_lock_routing"
  table w3_lock_routing_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?
end

W3_LOCK_ROUTING_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "w3_lock_routing", [:one, :two],
  ["CREATE TABLE w3_lock_routing_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT)"]
)

W3_LOCK_ROUTING_CLAUSE = Grant::Locking.clause("FOR NO KEY UPDATE")

def w3_lock_routing_record_on_two : W3LockRoutingThing
  W3LockRoutingThing.create!(tenant_id: 2_i64, label: "before")
  record = W3LockRoutingThing.where(tenant_id: 2_i64).first!
  W3_LOCK_ROUTING_FIXTURE.exec(:two, "UPDATE w3_lock_routing_things SET label = 'locked value'")
  record
end

describe "Pessimistic lock options on a sharded model" do
  before_each do
    W3_LOCK_ROUTING_FIXTURE.set_up
  end

  after_each do
    W3_LOCK_ROUTING_FIXTURE.tear_down
  end

  it "runs lock!(force: true) on the record's own shard" do
    record = w3_lock_routing_record_on_two
    record.label = "unsaved"

    record.lock!(force: true).label.should eq "locked value"
    Grant::ShardManager.current_shard.should be_nil
  end

  it "runs reload_with_lock on the record's own shard" do
    record = w3_lock_routing_record_on_two

    record.reload_with_lock.label.should eq "locked value"
  end

  it "runs lock! with a custom clause on the record's own shard" do
    record = w3_lock_routing_record_on_two

    record.lock!(W3_LOCK_ROUTING_CLAUSE).label.should eq "locked value"
  end

  it "runs with_lock(requires_new: true) and its block on the record's own shard" do
    record = w3_lock_routing_record_on_two

    shard_in_block = record.with_lock(requires_new: true) do |locked|
      locked.label.should eq "locked value"
      Grant::ShardManager.current_shard
    end

    shard_in_block.should eq :two
    Grant::ShardManager.current_shard.should be_nil
  end

  it "runs with_lock with a custom clause and its block on the record's own shard" do
    record = w3_lock_routing_record_on_two

    shard_in_block = record.with_lock(W3_LOCK_ROUTING_CLAUSE) do |locked|
      locked.label.should eq "locked value"
      Grant::ShardManager.current_shard
    end

    shard_in_block.should eq :two
  end
end
