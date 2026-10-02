require "../../spec_helper"

class C01PredicateBase < Grant::Base
  table c01_predicate_bases
  column id : Int64, primary: true
end

class C01PredicateOther < Grant::Base
  table c01_predicate_others
  column id : Int64, primary: true
end

class C01PredicateChild < C01PredicateBase
end

describe "connected_to? / connecting_to / connected_to_many" do
  describe "connected_to?" do
    it "reports the role and shard in effect" do
      C01PredicateBase.connected_to?(role: :writing).should be_true
      C01PredicateBase.connected_to?(role: :reading).should be_false

      C01PredicateBase.connected_to(role: :reading, shard: :one) do
        C01PredicateBase.connected_to?(role: :reading).should be_true
        C01PredicateBase.connected_to?(role: :reading, shard: :one).should be_true
        C01PredicateBase.connected_to?(role: :reading, shard: :two).should be_false
        C01PredicateBase.connected_to?(role: :writing).should be_false
        C01PredicateBase.connected_to?(shard: :one).should be_true
      end

      C01PredicateBase.connected_to?(role: :reading).should be_false
    end

    it "counts an unsharded connection as the default shard" do
      C01PredicateBase.connected_to?(shard: :default).should be_true
      C01PredicateBase.connected_to?(shard: :one).should be_false
    end

    it "requires a role or a shard" do
      expect_raises(ArgumentError) { C01PredicateBase.connected_to? }
    end

    it "applies a parent's block to subclasses but not to unrelated models" do
      C01PredicateBase.connected_to(role: :reading) do
        C01PredicateChild.connected_to?(role: :reading).should be_true
        C01PredicateOther.connected_to?(role: :reading).should be_false
      end

      C01PredicateChild.connected_to(role: :reading) do
        C01PredicateBase.connected_to?(role: :reading).should be_false
      end
    end
  end

  describe "connecting_to" do
    it "switches the fiber without a block until reset" do
      C01PredicateBase.connecting_to(role: :reading, shard: :one)
      begin
        C01PredicateBase.connected_to?(role: :reading, shard: :one).should be_true
        C01PredicateBase.preventing_writes?.should be_true
        C01PredicateOther.connected_to?(role: :reading).should be_false
      ensure
        C01PredicateBase.reset_connecting_to
      end

      C01PredicateBase.connected_to?(role: :reading).should be_false
      C01PredicateBase.current_shard.should be_nil
    end

    it "is fiber-local" do
      seen = Channel(Bool).new
      C01PredicateBase.connecting_to(role: :reading)
      begin
        spawn { seen.send(C01PredicateBase.connected_to?(role: :reading)) }
        seen.receive.should be_false
        C01PredicateBase.connected_to?(role: :reading).should be_true
      ensure
        C01PredicateBase.reset_connecting_to
      end
    end
  end

  describe "connected_to_many" do
    it "switches every listed class, and only those" do
      value = Grant.connected_to_many(C01PredicateBase, C01PredicateOther, role: :reading) do
        C01PredicateBase.connected_to?(role: :reading).should be_true
        C01PredicateOther.connected_to?(role: :reading).should be_true
        Todo.connected_to?(role: :reading).should be_false
        42
      end

      value.should eq 42
      C01PredicateBase.connected_to?(role: :reading).should be_false
      C01PredicateOther.connected_to?(role: :reading).should be_false
    end

    it "accepts an array literal and passes shard and prevent_writes" do
      Grant.connected_to_many([C01PredicateBase, C01PredicateOther], shard: :one, prevent_writes: true) do
        C01PredicateBase.current_shard.should eq :one
        C01PredicateOther.current_shard.should eq :one
        C01PredicateOther.preventing_writes?.should be_true
      end
    end

    it "restores contexts when the block raises" do
      expect_raises(Exception, "boom") do
        Grant.connected_to_many(C01PredicateBase, C01PredicateOther, role: :reading) { raise "boom" }
      end
      C01PredicateBase.connection_context.should be_nil
      C01PredicateOther.connection_context.should be_nil
    end
  end
end
