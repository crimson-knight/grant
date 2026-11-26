require "../../spec_helper"

# The transaction stack and the unscoped-model names live in slots on the
# fiber. These examples pin what that means: each fiber sees only its own
# state, nested blocks push and pop on it, and the slot empties after the
# outermost block.
describe "fiber-local transaction state" do
  it "keeps the stack on the fiber and empties it after the outermost block" do
    Fiber.current.grant_transaction_stack.should be_nil

    Parent.transaction do
      Grant::Transaction.fiber_stack.size.should eq(1)
      Parent.transaction(requires_new: true) do
        # A savepoint nests on the open level, so the stack keeps one state.
        Grant::Transaction.fiber_stack.size.should eq(1)
        Grant::Transaction.in_explicit_transaction?.should be_true
      end
      Grant::Transaction.fiber_stack.size.should eq(1)
    end

    Fiber.current.grant_transaction_stack.should be_nil
    Grant::Transaction.in_explicit_transaction?.should be_false
  end

  it "empties the slot when the outermost block raises" do
    expect_raises(Exception, "boom") do
      Parent.transaction do
        Parent.transaction(requires_new: true) { raise "boom" }
      end
    end

    Fiber.current.grant_transaction_stack.should be_nil
  end

  it "gives a fiber spawned inside a transaction no transaction of its own" do
    seen = Channel(Bool).new

    Parent.transaction do
      spawn do
        seen.send(Grant::Transaction.in_explicit_transaction?)
      end
      seen.receive.should be_false
      Grant::Transaction.in_explicit_transaction?.should be_true
    end
  end

  it "keeps two fibers' open transactions apart" do
    inside = Channel(Nil).new
    release = Channel(Nil).new
    other_stack = Channel({Int32, Array(Grant::Transaction::TransactionState)}).new

    spawn do
      Parent.transaction do
        Parent.transaction(requires_new: true) do
          inside.send(nil)
          release.receive
          stack = Grant::Transaction.fiber_stack
          other_stack.send({stack.size, stack})
        end
      end
    end

    inside.receive
    Grant::Transaction.in_explicit_transaction?.should be_false
    Parent.transaction do
      Grant::Transaction.fiber_stack.size.should eq(1)
      release.send(nil)
      stack = Grant::Transaction.fiber_stack
      stack.size.should eq(1)
      other_size, other = other_stack.receive
      other_size.should eq(1)
      other.should_not be(stack)
    end
  end

  it "keeps unscoped blocks to the fiber that opened them" do
    seen = Channel(Bool).new

    Grant::Scoping.set_unscoped("Parent", true)
    begin
      Grant::Scoping.unscoped?("Parent").should be_true
      Grant::Scoping.unscoped?("Teacher").should be_false
      spawn { seen.send(Grant::Scoping.unscoped?("Parent")) }
      seen.receive.should be_false
    ensure
      Grant::Scoping.set_unscoped("Parent", false)
    end

    Grant::Scoping.unscoped?("Parent").should be_false
    Fiber.current.grant_unscoped_models.should be_nil
  end
end
