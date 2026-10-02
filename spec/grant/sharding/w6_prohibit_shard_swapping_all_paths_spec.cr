require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../../src/grant/sharding"

class W6SwapThing < Grant::Base
  include Grant::Sharding::Model

  connection "w6_swap"
  table w6_swap_things
  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :w6_swap_a, "2" => :w6_swap_b}, default_shard: nil
end

private def prohibited(&)
  W6SwapThing.connected_to(shard: :w6_swap_a) do
    W6SwapThing.prohibit_shard_swapping { yield }
  end
end

describe "prohibit_shard_swapping on every path to another shard (#{CURRENT_ADAPTER})" do
  before_all do
    ddl = ["CREATE TABLE w6_swap_things (#{W6C04.id_column}, tenant_id BIGINT NOT NULL, label TEXT)"]
    {w6_swap_a: 1_i64, w6_swap_b: 2_i64}.each do |shard, tenant|
      W6C04.provision("w6_swap_#{shard}", ddl)
      W6C04.establish("w6_swap", "w6_swap_#{shard}", :primary, shard)
      W6C04.exec("w6_swap_#{shard}", "INSERT INTO w6_swap_things (tenant_id, label) VALUES (#{tenant}, 'row of #{shard}')")
    end
  end

  after_all do
    {:w6_swap_a, :w6_swap_b}.each { |shard| W6C04.remove("w6_swap", :primary, shard) }
    W6C04.cleanup
  end

  it "stops connected_to(shard:)" do
    prohibited { expect_raises(Grant::ShardSwappingProhibited) { W6SwapThing.connected_to(shard: :w6_swap_b) { } } }
  end

  it "stops ShardManager.with_shard" do
    prohibited { expect_raises(Grant::ShardSwappingProhibited) { Grant::ShardManager.with_shard(:w6_swap_b) { } } }
    Grant::ShardManager.current_shard.should be_nil
  end

  it "stops ShardManager.on_shard" do
    prohibited do
      expect_raises(Grant::ShardSwappingProhibited) do
        Grant::ShardManager.on_shard(:w6_swap_b, "w6_swap") { |_adapter| }
      end
    end
  end

  it "stops ShardManager.on_all_shards" do
    prohibited do
      expect_raises(Grant::ShardSwappingProhibited) do
        Grant::ShardManager.on_all_shards("W6SwapThing", "w6_swap") { |_shard, _adapter| 1 }
      end
    end
  end

  it "stops Model.on_shard and Model.on_all_shards, query and block forms" do
    prohibited do
      expect_raises(Grant::ShardSwappingProhibited) { W6SwapThing.on_shard(:w6_swap_b) }
      expect_raises(Grant::ShardSwappingProhibited) { W6SwapThing.on_all_shards.count }
      expect_raises(Grant::ShardSwappingProhibited) { W6SwapThing.on_all_shards { } }
    end
  end

  it "stops a query builder pinned to another shard" do
    prohibited do
      builder = W6SwapThing.__builder.as(Grant::Sharding::ShardedQueryBuilder(W6SwapThing))
      expect_raises(Grant::ShardSwappingProhibited) { builder.on_shard(:w6_swap_b) }
      expect_raises(Grant::ShardSwappingProhibited) { builder.on_all_shards }
    end
  end

  it "stops find_each_shard and move_to_shard" do
    record = W6SwapThing.connected_to(shard: :w6_swap_a) { W6SwapThing.first! }
    prohibited do
      expect_raises(Grant::ShardSwappingProhibited) { W6SwapThing.find_each_shard { |_| } }
      expect_raises(Grant::ShardSwappingProhibited) { record.move_to_shard(:w6_swap_b) }
    end
  end

  it "leaves the shard the request is pinned to alone, and its data" do
    prohibited do
      W6SwapThing.current_shard.should eq :w6_swap_a
      W6SwapThing.order(id: :asc).select.map(&.label).should eq ["row of w6_swap_a"]
      W6SwapThing.count.should eq 1
    end
  end

  it "still routes a record to the shard its key resolves to" do
    W6SwapThing.prohibit_shard_swapping do
      record = W6SwapThing.new(tenant_id: 2_i64, label: "routed by key")
      record.save!
      record.current_shard.should eq :w6_swap_b
      W6SwapThing.where(tenant_id: 2_i64).select.map(&.label).should contain "routed by key"
    end
    W6C04.strings("w6_swap_w6_swap_b", "SELECT label FROM w6_swap_things ORDER BY id").should eq ["row of w6_swap_b", "routed by key"]
    W6C04.exec("w6_swap_w6_swap_b", "DELETE FROM w6_swap_things WHERE label = 'routed by key'")
  end

  it "still allows role and database switches" do
    prohibited do
      W6SwapThing.connected_to(role: :reading) { W6SwapThing.current_role.should eq :reading }
    end
  end

  it "reports the flag and lifts it with the block, also on an error" do
    W6SwapThing.shard_swapping_prohibited?.should be_false
    expect_raises(Exception, "boom") { W6SwapThing.prohibit_shard_swapping { raise "boom" } }
    W6SwapThing.shard_swapping_prohibited?.should be_false
    Grant::ShardManager.with_shard(:w6_swap_b) { Grant::ShardManager.current_shard }.should eq :w6_swap_b
  end

  it "can be lifted for an inner block" do
    W6SwapThing.prohibit_shard_swapping do
      W6SwapThing.prohibit_shard_swapping(false) do
        Grant::ShardManager.with_shard(:w6_swap_b) { Grant::ShardManager.current_shard }.should eq :w6_swap_b
      end
      expect_raises(Grant::ShardSwappingProhibited) { Grant::ShardManager.with_shard(:w6_swap_b) { } }
    end
  end

  it "does not reach another fiber" do
    seen = Channel(Symbol?).new
    W6SwapThing.prohibit_shard_swapping do
      spawn { seen.send(Grant::ShardManager.with_shard(:w6_swap_b) { Grant::ShardManager.current_shard }) }
      seen.receive.should eq :w6_swap_b
    end
  end
end
