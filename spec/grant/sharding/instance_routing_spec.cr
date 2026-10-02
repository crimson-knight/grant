require "../../spec_helper"
require "../../support/real_sqlite_shards"

class S02InstanceThing < Grant::Base
  connection "s02_instances"
  table s02_instance_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?
  column counter : Int64 = 0_i64
  column flag : Bool = false
end

S02_INSTANCE_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_instances", [:one, :two],
  ["CREATE TABLE s02_instance_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT, counter INTEGER NOT NULL DEFAULT 0, flag BOOLEAN NOT NULL DEFAULT 0)"]
)

def s02_instance_ids(shard : Symbol) : Array(Int64)
  S02_INSTANCE_FIXTURE.int_values(shard, "SELECT id FROM s02_instance_things ORDER BY id")
end

describe "Instance writes on a sharded model" do
  before_each do
    S02_INSTANCE_FIXTURE.set_up
  end

  after_each do
    S02_INSTANCE_FIXTURE.tear_down
  end

  it "saves a new record to the shard its key resolves to, outside with_shard" do
    Grant::ShardManager.current_shard.should be_nil

    one = S02InstanceThing.new(tenant_id: 1_i64, label: "first")
    one.save!
    two = S02InstanceThing.new(tenant_id: 2_i64, label: "second")
    two.save!

    s02_instance_ids(:one).should eq [one.id.not_nil!]
    s02_instance_ids(:two).should eq [two.id.not_nil!]
    one.current_shard.should eq :one
    two.current_shard.should eq :two
  end

  it "creates records on the right shard with create and create!" do
    made = S02InstanceThing.create!(tenant_id: 2_i64, label: "made")
    plain = S02InstanceThing.create(tenant_id: 1_i64, label: "plain")

    s02_instance_ids(:two).should eq [made.id.not_nil!]
    s02_instance_ids(:one).should eq [plain.id.not_nil!]
  end

  it "leaves no shard active after a save" do
    S02InstanceThing.new(tenant_id: 1_i64).save!
    Grant::ShardManager.current_shard.should be_nil
  end

  it "sets current_shard on records a sharded query loads" do
    S02InstanceThing.create!(tenant_id: 1_i64, label: "a")
    S02InstanceThing.create!(tenant_id: 2_i64, label: "b")

    loaded = S02InstanceThing.order(id: :asc).select
    loaded.map(&.current_shard).should eq [:one, :two]
    S02InstanceThing.where(tenant_id: 2_i64).first!.current_shard.should eq :two
    S02InstanceThing.find(loaded.first.id.not_nil!).not_nil!.current_shard.should eq :one
  end

  it "updates a loaded record outside with_shard" do
    S02InstanceThing.create!(tenant_id: 2_i64, label: "before")
    record = S02InstanceThing.where(tenant_id: 2_i64).first!

    record.label = "after"
    record.save!
    record.update!(counter: 5_i64)
    record.update(flag: true).should be_true

    S02InstanceThing.connected_to(shard: :two) do
      fresh = S02InstanceThing.first!
      fresh.label.should eq "after"
      fresh.counter.should eq 5_i64
      fresh.flag.should be_true
    end
    s02_instance_ids(:one).should be_empty
  end

  it "runs column-level writes on the record's shard" do
    S02InstanceThing.create!(tenant_id: 2_i64, label: "before")
    record = S02InstanceThing.where(tenant_id: 2_i64).first!

    record.update_columns(label: "columns").should be_true
    record.update_column(:counter, 3_i64).should be_true
    record.increment!(:counter)
    record.toggle!(:flag)

    record.reload
    record.label.should eq "columns"
    record.counter.should eq 4_i64
    record.flag.should be_true
    record.current_shard.should eq :two
  end

  it "reloads a record from its own shard" do
    S02InstanceThing.create!(tenant_id: 2_i64, label: "before")
    record = S02InstanceThing.where(tenant_id: 2_i64).first!
    S02_INSTANCE_FIXTURE.exec(:two, "UPDATE s02_instance_things SET label = 'changed elsewhere'")

    record.reload.label.should eq "changed elsewhere"
  end

  it "locks a loaded record on its own shard, outside with_shard" do
    S02InstanceThing.create!(tenant_id: 2_i64, label: "before")
    record = S02InstanceThing.where(tenant_id: 2_i64).first!
    S02_INSTANCE_FIXTURE.exec(:two, "UPDATE s02_instance_things SET label = 'locked value'")

    record.lock!.label.should eq "locked value"
  end

  it "runs with_lock and its block on the record's own shard" do
    S02InstanceThing.create!(tenant_id: 2_i64, label: "before")
    record = S02InstanceThing.where(tenant_id: 2_i64).first!

    shard_in_block = record.with_lock do |locked|
      locked.label = "inside lock"
      locked.save!
      Grant::ShardManager.current_shard
    end

    shard_in_block.should eq :two
    Grant::ShardManager.current_shard.should be_nil
    S02InstanceThing.where(tenant_id: 2_i64).first!.label.should eq "inside lock"
  end

  it "destroys a loaded record outside with_shard" do
    keep = S02InstanceThing.create!(tenant_id: 1_i64, label: "keep")
    S02InstanceThing.create!(tenant_id: 2_i64, label: "drop")
    S02InstanceThing.create!(tenant_id: 2_i64, label: "drop too")

    S02InstanceThing.where(tenant_id: 2_i64).order(id: :asc).select.each(&.destroy!)

    s02_instance_ids(:two).should be_empty
    s02_instance_ids(:one).should eq [keep.id.not_nil!]
  end

  it "deletes a loaded record outside with_shard" do
    S02InstanceThing.create!(tenant_id: 1_i64, label: "gone")
    S02InstanceThing.first!.delete

    s02_instance_ids(:one).should be_empty
  end

  it "destroys with destroy as well as destroy!" do
    S02InstanceThing.create!(tenant_id: 1_i64, label: "gone")
    S02InstanceThing.first!.destroy.should be_true

    s02_instance_ids(:one).should be_empty
  end

  it "re-resolves the shard while a new record's key changes before its first save" do
    record = S02InstanceThing.new(tenant_id: 1_i64, label: "moving")
    record.determine_shard.should eq :one

    record.tenant_id = 2_i64
    record.determine_shard.should eq :two

    record.save!
    s02_instance_ids(:two).should eq [record.id.not_nil!]
    s02_instance_ids(:one).should be_empty
  end

  it "caches the shard on the record between writes" do
    record = S02InstanceThing.create!(tenant_id: 1_i64, label: "cached")
    record.current_shard.should eq :one

    record.label = "again"
    record.save!
    record.determine_shard.should eq :one
    record.current_shard.should eq :one
  end

  it "honors a shard pinned by hand" do
    record = S02InstanceThing.new(tenant_id: 1_i64, label: "pinned")
    record.current_shard = :two
    record.save!

    s02_instance_ids(:two).should eq [record.id.not_nil!]
    s02_instance_ids(:one).should be_empty
  end

  it "writes a record to its own shard even when another shard is active" do
    record = S02InstanceThing.new(tenant_id: 1_i64, label: "own shard")
    Grant::ShardManager.with_shard(:two) { record.save! }

    s02_instance_ids(:one).should eq [record.id.not_nil!]
    s02_instance_ids(:two).should be_empty
  end

  it "still saves inside with_shard for the shard that is active" do
    record = S02InstanceThing.new(tenant_id: 2_i64, label: "inside")
    Grant::ShardManager.with_shard(:two) { record.save! }

    s02_instance_ids(:two).should eq [record.id.not_nil!]
  end
end
