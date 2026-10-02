require "../../spec_helper"
require "../../support/real_sqlite_shards"

# Tenants 1 and 3 live on shard one; tenant 2 lives on shard two.
class S02KeyedThing < Grant::Base
  connection "s02_keys"
  table s02_keyed_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "3" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?
end

S02_KEY_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_keys", [:one, :two],
  ["CREATE TABLE s02_keyed_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT)"]
)

def s02_key_rows(shard : Symbol) : Array(Int64)
  S02_KEY_FIXTURE.int_values(shard, "SELECT tenant_id FROM s02_keyed_things ORDER BY id")
end

describe "Shard key immutability" do
  before_each do
    S02_KEY_FIXTURE.set_up
    S02KeyedThing.create!(tenant_id: 1_i64, label: "row")
  end

  after_each do
    S02_KEY_FIXTURE.tear_down
  end

  it "refuses to save a persisted record whose shard key changed" do
    record = S02KeyedThing.first!
    record.tenant_id = 2_i64

    expect_raises(Grant::Sharding::ShardKeyChangedError, /tenant_id/) { record.save! }
    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.save }
    s02_key_rows(:one).should eq [1_i64]
    s02_key_rows(:two).should be_empty
  end

  it "refuses even a change that stays on the same shard" do
    record = S02KeyedThing.first!
    record.tenant_id = 3_i64

    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.save! }
    s02_key_rows(:one).should eq [1_i64]
  end

  it "refuses update and update! that change the key" do
    record = S02KeyedThing.first!

    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.update!(tenant_id: 2_i64) }
    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.update(tenant_id: 2_i64) }
    s02_key_rows(:one).should eq [1_i64]
  end

  it "refuses column-level writes to the key" do
    record = S02KeyedThing.first!

    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.update_columns(tenant_id: 2_i64) }
    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.update_column(:tenant_id, 2_i64) }
    expect_raises(Grant::Sharding::ShardKeyChangedError) { record.increment!(:tenant_id) }
    s02_key_rows(:one).should eq [1_i64]
  end

  it "saves other columns and a key set to its current value" do
    record = S02KeyedThing.first!
    record.tenant_id = 1_i64
    record.label = "changed"
    record.save!

    S02KeyedThing.first!.label.should eq "changed"
  end

  it "lets a new record change its key before the first save" do
    record = S02KeyedThing.new(tenant_id: 1_i64, label: "new")
    record.tenant_id = 2_i64
    record.save!

    s02_key_rows(:two).should eq [2_i64]
  end

  it "moves a record to another shard with move_to_shard" do
    record = S02KeyedThing.first!
    record.tenant_id = 2_i64

    moved = record.move_to_shard(:two)

    moved.current_shard.should eq :two
    s02_key_rows(:one).should be_empty
    s02_key_rows(:two).should eq [2_i64]
    S02KeyedThing.first!.label.should eq "row"
  end
end
