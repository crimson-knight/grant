require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../../src/grant/sharding"

# Each shard has a writer and a reader database. The reader rows differ from
# the writer rows, so what a query returns names the database it reached. The
# pairs come from connects_to(shards: {writing:, reading:}).
class W6ShardReplicaThing < Grant::Base
  include Grant::Sharding::Model

  table w6_shard_replica_things
  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String

  connects_to shards: {
    shard_one: {writing: "w6_sr_one", reading: "w6_sr_one_r"},
    shard_two: {writing: "w6_sr_two", reading: "w6_sr_two_r"},
  }
  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :shard_one, "2" => :shard_two}, default_shard: nil
end

private def w6_sr_labels(name : String) : Array(String)
  W6C04.strings(name, "SELECT label FROM w6_shard_replica_things ORDER BY id")
end

describe "per-shard read replicas (#{CURRENT_ADAPTER})" do
  before_all do
    ddl = ["CREATE TABLE w6_shard_replica_things (#{W6C04.id_column}, tenant_id BIGINT NOT NULL, label TEXT NOT NULL)"]
    {"w6_sr_one" => {1, "one writer"}, "w6_sr_one_r" => {1, "one reader"}, "w6_sr_two" => {2, "two writer"}, "w6_sr_two_r" => {2, "two reader"}}.each do |name, (tenant, label)|
      W6C04.provision(name, ddl)
      W6C04.exec(name, "INSERT INTO w6_shard_replica_things (tenant_id, label) VALUES (#{tenant}, '#{label}')")
      W6C04.establish(name, name, name.ends_with?("_r") ? :reading : :writing)
    end
  end

  after_all do
    %w[w6_sr_one w6_sr_one_r w6_sr_two w6_sr_two_r].each do |name|
      W6C04.remove(name, :writing)
      W6C04.remove(name, :reading)
    end
    W6C04.cleanup
  end

  it "reads the shard writer by default" do
    W6ShardReplicaThing.connected_to(shard: :shard_one) { W6ShardReplicaThing.first!.label }.should eq "one writer"
    W6ShardReplicaThing.connected_to(shard: :shard_two) { W6ShardReplicaThing.first!.label }.should eq "two writer"
  end

  it "reads the shard reader inside connected_to(role: :reading, shard:)" do
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_one) { W6ShardReplicaThing.first!.label }.should eq "one reader"
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_two) { W6ShardReplicaThing.first!.label }.should eq "two reader"
  end

  it "resolves the reader and writer adapters of a shard" do
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_one) { W6ShardReplicaThing.adapter.url }.should contain W6C04.url("w6_sr_one_r")
    W6ShardReplicaThing.connected_to(role: :writing, shard: :shard_one) { W6ShardReplicaThing.adapter.url }.should_not contain "w6_sr_one_r"
    W6ShardReplicaThing.adapter_for_shard(:shard_two, :reading).url.should contain W6C04.url("w6_sr_two_r")
  end

  it "answers connected_to? for the role and shard together" do
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_one) do
      W6ShardReplicaThing.connected_to?(role: :reading, shard: :shard_one).should be_true
      W6ShardReplicaThing.connected_to?(role: :reading, shard: :shard_two).should be_false
      W6ShardReplicaThing.connected_to?(role: :writing, shard: :shard_one).should be_false
      W6ShardReplicaThing.preventing_writes?.should be_true
    end
  end

  it "reads every shard reader when a scatter query runs in the reading role" do
    W6ShardReplicaThing.connected_to(role: :reading) { W6ShardReplicaThing.order(id: :asc).select.map(&.label) }.should eq ["one reader", "two reader"]
  end

  it "aggregates from the shard readers in the reading role" do
    W6ShardReplicaThing.connected_to(role: :reading) { W6ShardReplicaThing.count }.should eq 2_i64
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_two) { W6ShardReplicaThing.where(label: "two reader").count }.should eq 1_i64
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_two) { W6ShardReplicaThing.where(label: "two writer").count }.should eq 0_i64
  end

  it "refuses a write in the reading role and leaves every database alone" do
    expect_raises(Grant::Transaction::ReadOnlyError) do
      W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_one) do
        W6ShardReplicaThing.new(tenant_id: 1_i64, label: "refused").save!
      end
    end

    w6_sr_labels("w6_sr_one").should eq ["one writer"]
    w6_sr_labels("w6_sr_one_r").should eq ["one reader"]
  end

  it "writes a record to its shard's writer, never its reader" do
    W6ShardReplicaThing.new(tenant_id: 2_i64, label: "written").save!

    w6_sr_labels("w6_sr_two").should eq ["two writer", "written"]
    w6_sr_labels("w6_sr_two_r").should eq ["two reader"]
    W6C04.exec("w6_sr_two", "DELETE FROM w6_shard_replica_things WHERE label = 'written'")
  end

  it "lifts the write prevention of the reading role with an explicit writing role" do
    W6ShardReplicaThing.connected_to(role: :reading, shard: :shard_one) do
      W6ShardReplicaThing.connected_to(role: :writing, shard: :shard_one) do
        W6ShardReplicaThing.preventing_writes?.should be_false
        W6ShardReplicaThing.first!.label.should eq "one writer"
      end
    end
  end
end
