require "../../spec_helper"
require "./sql_recorder"

describe "Savepoint failure handling" do
  it "rolls back only the savepoint when a non-Rollback exception escapes it" do
    Parent.clear

    Parent.transaction do
      Parent.create!(name: "Kept")
      begin
        Parent.transaction(requires_new: true) do
          Parent.create!(name: "Discarded")
          raise "inner failure"
        end
      rescue ex
        ex.message.should eq("inner failure")
      end
      Parent.create!(name: "After")
    end

    Parent.all.map(&.name.to_s).sort!.should eq(["After", "Kept"])
  end

  it "recovers an aborted PostgreSQL transaction via ROLLBACK TO SAVEPOINT" do
    Parent.clear

    statements = TransactionSqlRecorder.record do
      Parent.transaction do
        Parent.create!(name: "Kept")
        begin
          Parent.transaction(requires_new: true) do
            # A failing statement aborts a PostgreSQL transaction until the
            # savepoint is rolled back.
            Parent.connection.execute("INSERT INTO no_such_table_for_savepoint_spec (x) VALUES (1)")
          end
        rescue Exception
        end
        Parent.create!(name: "After")
      end
    end

    Parent.all.map(&.name.to_s).sort!.should eq(["After", "Kept"])
    statements.any?(&.starts_with?("ROLLBACK TO SAVEPOINT")).should be_true
    statements.last.should eq("COMMIT")
  end

  it "prunes callbacks registered inside a rolled-back savepoint" do
    events = [] of Symbol
    Parent.transaction do
      Parent.current_transaction.after_commit { events << :outer_commit }
      Parent.transaction(requires_new: true) do
        Parent.current_transaction.after_commit { events << :inner_commit }
        Parent.current_transaction.after_rollback { events << :inner_rollback }
        raise Grant::Transaction::Rollback.new
      end
      # The pruned callback already got after_rollback at the savepoint.
      events.should eq([:inner_rollback])
    end

    events.should eq([:inner_rollback, :outer_commit])
  end

  it "keeps callbacks from a released savepoint pending until the outer commit" do
    events = [] of Symbol
    Parent.transaction do
      Parent.transaction(requires_new: true) do
        Parent.current_transaction.after_commit { events << :inner_commit }
      end
      events.should be_empty
    end

    events.should eq([:inner_commit])
  end

  it "fires the released savepoint's rollback callback when the outer transaction rolls back" do
    events = [] of Symbol
    expect_raises(Exception, "outer") do
      Parent.transaction do
        Parent.transaction(requires_new: true) do
          Parent.current_transaction.after_commit { events << :inner_commit }
          Parent.current_transaction.after_rollback { events << :inner_rollback }
        end
        raise "outer"
      end
    end

    events.should eq([:inner_rollback])
  end

  it "restores in-memory record state written inside a rolled-back savepoint" do
    Parent.clear
    parent = Parent.new(name: "Fresh")

    Parent.transaction do
      Parent.transaction(requires_new: true) do
        parent.save!
        parent.persisted?.should be_true
        raise Grant::Transaction::Rollback.new
      end
    end

    parent.new_record?.should be_true
    Parent.count.should eq(0)
  end

  it "leaves no transaction open after a failed savepoint" do
    expect_raises(Exception, "boom") do
      Parent.transaction { Parent.transaction(requires_new: true) { raise "boom" } }
    end

    Parent.transaction_open?.should be_false
    Grant::Transaction.in_explicit_transaction?.should be_false
  end

  it "keeps savepoint names unique after a rollback" do
    statements = TransactionSqlRecorder.record do
      Parent.transaction do
        Parent.transaction(requires_new: true) { raise Grant::Transaction::Rollback.new }
        Parent.transaction(requires_new: true) { }
      end
    end

    statements.select(&.starts_with?("SAVEPOINT")).should eq(["SAVEPOINT sp_1", "SAVEPOINT sp_2"])
  end
end
