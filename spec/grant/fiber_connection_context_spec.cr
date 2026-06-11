require "../spec_helper"

# Model for fiber connection context tests
class FiberCMTestModel < Grant::Base
  connection sqlite
  table fiber_cm_test_models

  column id : Int64, primary: true
  column content : String?
end

# Spec for Bug 2: connection_context must be fiber-local, not class-global.
# Two fibers entering connected_to with different roles must not see each other's context.
describe "Grant::ConnectionManagement fiber-local connection_context" do
  it "isolates connection_context between concurrent fibers" do
    # Use a Channel to sequence interleaving deterministically:
    #   fiber_a sets its context, then signals fiber_b
    #   fiber_b sets its own context and checks it is :reading, then signals main
    #   main checks fiber_a's context is still :primary

    fiber_a_entered  = Channel(Nil).new
    fiber_b_entered  = Channel(Nil).new
    fiber_a_finished = Channel(Nil).new

    role_seen_by_a = nil.as(Symbol?)
    role_seen_by_b = nil.as(Symbol?)

    fiber_a = spawn do
      FiberCMTestModel.connected_to(role: :primary) do
        # Signal fiber_b to enter its block now
        fiber_a_entered.send(nil)
        # Wait for fiber_b to have set its context
        fiber_b_entered.receive
        # Read context from inside our own block — must still be :primary
        role_seen_by_a = FiberCMTestModel.current_role
      end
      fiber_a_finished.send(nil)
    end

    fiber_b = spawn do
      # Wait for fiber_a to have set its context before proceeding
      fiber_a_entered.receive
      FiberCMTestModel.connected_to(role: :reading) do
        role_seen_by_b = FiberCMTestModel.current_role
        # Signal fiber_a that we have set our context
        fiber_b_entered.send(nil)
      end
    end

    fiber_a_finished.receive

    role_seen_by_a.should eq(:primary)
    role_seen_by_b.should eq(:reading)
  end

  it "cleans up fiber entry from hash when restoring to nil (no memory leak)" do
    # After a connected_to block exits and restores to nil,
    # the fiber's key should be absent from the backing hash.
    FiberCMTestModel.connected_to(role: :primary) do
      # inside the block context is set
      FiberCMTestModel.connection_context.should_not be_nil
    end
    # outside the block the context should be nil and the key deleted
    FiberCMTestModel.connection_context.should be_nil
  end
end
