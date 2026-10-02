require "../../spec_helper"
require "./sql_recorder"

describe "Transaction requires_new" do
  it "opens a SAVEPOINT on the pinned connection instead of a second transaction" do
    Parent.clear

    statements = TransactionSqlRecorder.record do
      Parent.transaction do
        Parent.transaction(requires_new: true) do
          Parent.create!(name: "Inner")
        end
      end
    end

    TransactionSqlRecorder.begins(statements).size.should eq(1)
    statements.should contain("SAVEPOINT sp_1")
    statements.should contain("RELEASE SAVEPOINT sp_1")
    statements.count("COMMIT").should eq(1)
    Parent.count.should eq(1)
  end

  it "rolls the released savepoint back with the outer transaction" do
    Parent.clear

    expect_raises(Exception, "outer failure") do
      Parent.transaction do
        Parent.transaction(requires_new: true) { Parent.create!(name: "Inner") }
        Parent.create!(name: "Outer")
        raise "outer failure"
      end
    end

    Parent.count.should eq(0)
  end

  it "rolls back only the savepoint on Rollback and lets the outer transaction commit" do
    Parent.clear

    result = Parent.transaction do
      Parent.create!(name: "Kept")
      Parent.transaction(requires_new: true) do
        Parent.create!(name: "Discarded")
        raise Grant::Transaction::Rollback.new
      end
      :done
    end

    result.should eq(:done)
    Parent.all.map(&.name).should eq(["Kept"])
  end

  it "names savepoints from a per-transaction counter" do
    statements = TransactionSqlRecorder.record do
      Parent.transaction do
        Parent.transaction(requires_new: true) { }
        Parent.transaction(requires_new: true) { }
      end
    end

    statements.select(&.starts_with?("SAVEPOINT")).should eq(["SAVEPOINT sp_1", "SAVEPOINT sp_2"])
  end

  it "begins a real transaction when none is open" do
    statements = TransactionSqlRecorder.record do
      Parent.transaction(requires_new: true) { }
    end

    TransactionSqlRecorder.begins(statements).size.should eq(1)
    statements.none?(&.starts_with?("SAVEPOINT")).should be_true
  end

  describe "independent: true" do
    it "keeps the separate-connection mode: the inner transaction commits on its own" do
      Parent.clear

      expect_raises(Exception, "outer failure") do
        Parent.transaction do
          outer_connection = Grant::Transaction.current_connection?(Parent.adapter)
          Parent.transaction(independent: true) do
            Grant::Transaction.current_connection?(Parent.adapter).should_not eq(outer_connection)
            Parent.create!(name: "Inner")
          end
          raise "outer failure"
        end
      end

      Parent.all.map(&.name).should eq(["Inner"])
    end

    it "issues its own BEGIN" do
      statements = TransactionSqlRecorder.record do
        Parent.transaction do
          Parent.transaction(independent: true) { }
        end
      end

      TransactionSqlRecorder.begins(statements).size.should eq(2)
    end
  end
end
