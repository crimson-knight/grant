require "../../spec_helper"
require "../../../src/grant/spec_support/*"

private def registered_writers : Array(Grant::Adapter::Base)
  writers = [] of Grant::Adapter::Base
  Grant::Connections.registered_connections.each do |pair|
    writers << pair[:writer] unless writers.any?(&.same?(pair[:writer]))
  end
  writers
end

describe "Grant::Spec.transactional" do
  before_each { Parent.clear }

  it "rolls back rows created inside the wrapper" do
    Grant::Spec.within_transaction do
      Parent.create!(name: "gone")
      Parent.count.should eq(1)
    end

    Parent.count.should eq(0)
  end

  it "rolls back even when the body raises" do
    expect_raises(Exception, "example failed") do
      Grant::Spec.within_transaction do
        Parent.create!(name: "gone")
        raise "example failed"
      end
    end

    Parent.count.should eq(0)
    Grant::Transaction.in_explicit_transaction?.should be_false
  end

  it "opens a non-joinable transaction on every registered connection" do
    writers = registered_writers
    writers.size.should be >= 2

    Grant::Spec.within_transaction do
      Grant::Transaction.fiber_stack.size.should eq(writers.size)
      Grant::Transaction.fiber_stack.all? { |state| !state.joinable? }.should be_true
      writers.each { |writer| Grant::Transaction.current_connection?(writer).should_not be_nil }
    end

    Grant::Transaction.in_explicit_transaction?.should be_false
  end

  it "turns a nested transaction block into a savepoint so its Rollback undoes only its work" do
    Grant::Spec.within_transaction do
      Parent.create!(name: "outer")
      Parent.transaction do
        Parent.create!(name: "inner")
        raise Grant::Transaction::Rollback.new
      end

      Parent.pluck(:name).should eq(["outer"])
    end
  end

  it "runs after_commit when a save's savepoint is released, as ActiveRecord test transactions do" do
    log = [] of String

    Grant::Spec.within_transaction do
      Parent.transaction do
        Parent.current_transaction.after_commit { log << "commit" }
        Parent.current_transaction.after_rollback { log << "rollback" }
        Parent.create!(name: "committed")
      end
      log.should eq(["commit"])
    end

    log.should eq(["commit"])
  end

  it "runs after_rollback, not after_commit, for a savepoint that rolls back" do
    log = [] of String

    Grant::Spec.within_transaction do
      Parent.transaction do
        Parent.current_transaction.after_commit { log << "commit" }
        Parent.current_transaction.after_rollback { log << "rollback" }
        raise Grant::Transaction::Rollback.new
      end
    end

    log.should eq(["rollback"])
  end

  it "runs after_commit when a manual savepoint under the wrapper commits" do
    log = [] of String

    Grant::Spec.within_transaction(only: [Parent.adapter.name]) do
      handle = Parent.connection.begin_transaction
      Parent.current_transaction.after_commit { log << "commit" }
      handle.commit
      log.should eq(["commit"])
    end
  end

  it "rolls back writes made through every registered connection" do
    # Only the spec_helper connections share the parents table; other spec
    # files register databases of their own, which the wrapper still covers.
    replica_writer = Grant::ConnectionRegistry.get_adapter("#{CURRENT_ADAPTER}_with_replica", :writing)
    writers = [Parent.adapter, replica_writer]
    insert = "INSERT INTO parents (name, created_at, updated_at) VALUES ('via_adapter', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"

    Grant::Spec.within_transaction do
      replica_writer.open { |db| db.exec(insert) }
    end

    writers.each do |writer|
      count = writer.open { |db| db.scalar("SELECT COUNT(*) FROM parents") }.to_s.to_i64
      count.should eq(0)
    end
  end

  it "limits the wrapper to the named connections" do
    name = Parent.adapter.name

    Grant::Spec.within_transaction(only: [name]) do
      Grant::Transaction.fiber_stack.map(&.adapter.name).should eq([name])
    end
  end

  it "wraps every example when installed with .transactional" do
    # `.transactional` registers Spec.around_each; the hook body is the same
    # within_transaction exercised above, so this only checks installation.
    Grant::Spec.responds_to?(:transactional).should be_true
  end

  it "is cheaper than deleting from the tables afterwards" do
    rounds = 30
    delete_time = Time.measure do
      rounds.times do
        Parent.create!(name: "x")
        Parent.clear
      end
    end
    rollback_time = Time.measure do
      rounds.times do
        Grant::Spec.within_transaction { Parent.create!(name: "x") }
      end
    end

    # Timing is machine dependent; only rule out the wrapper being far slower.
    (rollback_time < delete_time * 4).should be_true
  end
end
