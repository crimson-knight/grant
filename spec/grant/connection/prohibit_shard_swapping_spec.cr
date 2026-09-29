require "../../spec_helper"
require "../../support/simple_virtual_sharding"

class C01ShardSwapModel < Grant::Base
  table c01_shard_swap_models
  column id : Int64, primary: true
end

describe "prohibit_shard_swapping" do
  it "raises when connected_to switches the shard inside the block" do
    C01ShardSwapModel.connected_to(shard: :tenant_a) do
      C01ShardSwapModel.prohibit_shard_swapping do
        expect_raises(Grant::ShardSwappingProhibited, /tenant_b/) do
          C01ShardSwapModel.connected_to(shard: :tenant_b) { }
        end
        C01ShardSwapModel.current_shard.should eq :tenant_a
      end
    end
  end

  it "applies to every model in the fiber" do
    C01ShardSwapModel.prohibit_shard_swapping do
      expect_raises(Grant::ShardSwappingProhibited) do
        Todo.connected_to(shard: :other) { }
      end
    end
  end

  it "still allows role and database switches" do
    C01ShardSwapModel.prohibit_shard_swapping do
      C01ShardSwapModel.connected_to(role: :reading) do
        C01ShardSwapModel.current_role.should eq :reading
      end
    end
  end

  it "lifts when the block ends, even when it raised" do
    expect_raises(Exception, "boom") do
      C01ShardSwapModel.prohibit_shard_swapping { raise "boom" }
    end

    C01ShardSwapModel.shard_swapping_prohibited?.should be_false
    C01ShardSwapModel.connected_to(shard: :tenant_b) { C01ShardSwapModel.current_shard }.should eq :tenant_b
  end

  it "nests, and false lifts the prohibition for the inner block" do
    C01ShardSwapModel.prohibit_shard_swapping do
      C01ShardSwapModel.prohibit_shard_swapping(false) do
        C01ShardSwapModel.connected_to(shard: :tenant_b) { }
      end
      C01ShardSwapModel.shard_swapping_prohibited?.should be_true
    end
  end

  it "does not leak into other fibers" do
    seen = Channel(Bool).new
    C01ShardSwapModel.prohibit_shard_swapping do
      spawn { seen.send(C01ShardSwapModel.shard_swapping_prohibited?) }
      seen.receive.should be_false
    end
  end

  it "scopes the connected shard to the class tree, not Grant::ShardManager" do
    C01ShardSwapModel.connected_to(shard: :tenant_a) do
      C01ShardSwapModel.current_shard.should eq :tenant_a
      Todo.current_shard.should be_nil
      Grant::ShardManager.current_shard.should be_nil
    end
  end
end
