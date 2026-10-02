require "../../spec_helper"

describe "after_all_transactions_commit" do
  it "runs immediately when no transaction is open" do
    ran = false
    Grant.after_all_transactions_commit { ran = true }
    ran.should be_true

    ran = false
    Parent.after_all_transactions_commit { ran = true }
    ran.should be_true
  end

  it "runs after the outermost commit, not when a nested block finishes" do
    events = [] of Symbol
    Parent.transaction do
      Parent.transaction do
        Grant.after_all_transactions_commit { events << :after_all }
      end
      events.should be_empty
      Parent.transaction(requires_new: true) do
        Parent.after_all_transactions_commit { events << :model }
      end
      events.should be_empty
    end

    events.should eq([:after_all, :model])
  end

  it "waits for the outer transaction when an independent inner transaction commits" do
    events = [] of Symbol
    Parent.transaction do
      Parent.transaction(independent: true) do
        Grant.after_all_transactions_commit { events << :after_all }
      end
      events.should be_empty
    end

    events.should eq([:after_all])
  end

  it "is dropped when the transaction rolls back" do
    events = [] of Symbol
    Parent.transaction do
      Grant.after_all_transactions_commit { events << :after_all }
      raise Grant::Transaction::Rollback.new
    end

    expect_raises(Exception, "boom") do
      Parent.transaction do
        Grant.after_all_transactions_commit { events << :after_all }
        raise "boom"
      end
    end

    events.should be_empty
  end

  it "is dropped when only its savepoint rolls back" do
    events = [] of Symbol
    Parent.transaction do
      Grant.after_all_transactions_commit { events << :kept }
      Parent.transaction(requires_new: true) do
        Grant.after_all_transactions_commit { events << :dropped }
        raise Grant::Transaction::Rollback.new
      end
    end

    events.should eq([:kept])
  end

  it "runs after the record after_commit callbacks of the same transaction" do
    events = [] of Symbol
    Parent.transaction do
      Grant.after_all_transactions_commit { events << :after_all }
      Parent.current_transaction.after_commit { events << :commit }
    end

    events.should eq([:commit, :after_all])
  end

  it "is owned by the registering fiber" do
    events = [] of Symbol
    done = Channel(Nil).new

    Parent.transaction do
      Grant.after_all_transactions_commit { events << :main }
      spawn do
        # This fiber has no open transaction, so its block runs at once and is
        # never queued on the main fiber's transaction.
        Grant.after_all_transactions_commit { events << :other }
        done.send(nil)
      end
      done.receive
      events.should eq([:other])
    end

    events.should eq([:other, :main])
  end
end
