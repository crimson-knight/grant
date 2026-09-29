require "../../spec_helper"

private def transaction_events(& : ->) : Array(Grant::Events::Transaction)
  events = [] of Grant::Events::Transaction
  handler = ->(event : Grant::Events::Transaction) { events << event; nil }
  Grant::Notifications.subscribed(Grant::Events::Transaction, handler) { yield }
  events
end

describe "Transaction notifications" do
  before_each { Parent.clear }

  it "publishes start and commit with a duration" do
    starts = [] of Grant::Events::TransactionStart
    start_handler = ->(event : Grant::Events::TransactionStart) { starts << event; nil }

    events = transaction_events do
      Grant::Notifications.subscribed(Grant::Events::TransactionStart, start_handler) do
        Parent.transaction { Parent.create!(name: "committed") }
      end
    end

    # create! runs in its own savepoint, reported with savepoint? true.
    starts = starts.reject(&.savepoint?)
    events = events.reject(&.savepoint?)
    starts.size.should eq(1)
    starts.first.connection.should eq(Parent.adapter.name)
    events.size.should eq(1)
    events.first.outcome.commit?.should be_true
    events.first.committed?.should be_true
    events.first.duration.should be >= Time::Span.zero
    events.first.connection.should eq(Parent.adapter.name)
  end

  it "publishes a rollback for Rollback and for an exception" do
    events = transaction_events do
      Parent.transaction { raise Grant::Transaction::Rollback.new }
      expect_raises(Exception, "boom") { Parent.transaction { raise "boom" } }
    end

    events.map(&.outcome).should eq([Grant::Events::TransactionOutcome::Rollback, Grant::Events::TransactionOutcome::Rollback])
    events.all?(&.rolled_back?).should be_true
  end

  it "publishes nothing for a joined nested block and a savepoint event for requires_new" do
    starts = [] of Grant::Events::TransactionStart
    start_handler = ->(event : Grant::Events::TransactionStart) { starts << event; nil }

    events = transaction_events do
      Grant::Notifications.subscribed(Grant::Events::TransactionStart, start_handler) do
        Parent.transaction do
          Parent.transaction { }
          Parent.transaction(requires_new: true) { }
          Parent.transaction(requires_new: true) { raise Grant::Transaction::Rollback.new }
        end
      end
    end

    starts.map(&.savepoint?).should eq([false, true, true])
    events.map { |event| {event.savepoint?, event.outcome} }.should eq([
      {true, Grant::Events::TransactionOutcome::Commit},
      {true, Grant::Events::TransactionOutcome::Rollback},
      {false, Grant::Events::TransactionOutcome::Commit},
    ])
    events.first.savepoint_name.should_not be_nil
  end

  it "publishes the outcome of a manual savepoint" do
    events = transaction_events do
      Parent.transaction do
        Parent.connection.begin_transaction.commit
        Parent.connection.begin_transaction.rollback
      end
    end

    events.map { |event| {event.savepoint?, event.outcome} }.should eq([
      {true, Grant::Events::TransactionOutcome::Commit},
      {true, Grant::Events::TransactionOutcome::Rollback},
      {false, Grant::Events::TransactionOutcome::Commit},
    ])
  end

  it "publishes the outcome of a manual transaction" do
    events = transaction_events do
      handle = Parent.connection.begin_transaction
      handle.rollback
      handle = Parent.connection.begin_transaction
      handle.commit
    end

    events.map(&.outcome).should eq([Grant::Events::TransactionOutcome::Rollback, Grant::Events::TransactionOutcome::Commit])
  end

  it "publishes nothing when no one subscribes" do
    Grant::Notifications.subscribed?(Grant::Events::Transaction).should be_false
    Parent.transaction { Parent.create!(name: "quiet") }
    Parent.count.should eq(1)
  end
end
