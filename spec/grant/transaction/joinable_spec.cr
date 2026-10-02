require "../../spec_helper"
require "./sql_recorder"

describe "Transaction joinable" do
  it "joins the parent for a plain nested block without a SAVEPOINT round trip" do
    statements = TransactionSqlRecorder.record do
      Parent.transaction do
        Parent.transaction { Parent.transaction { } }
      end
    end

    TransactionSqlRecorder.begins(statements).size.should eq(1)
    statements.none?(&.starts_with?("SAVEPOINT")).should be_true
  end

  it "swallows Rollback in a joined block without undoing anything" do
    Parent.clear

    inner_value = :unset
    Parent.transaction do
      Parent.create!(name: "Outer")
      inner_value = Parent.transaction do
        Parent.create!(name: "Inner")
        raise Grant::Transaction::Rollback.new
      end
      Parent.count.should eq(2)
    end

    inner_value.should be_nil
    Parent.count.should eq(2)
  end

  it "propagates a non-Rollback exception from a joined block and rolls the outer back" do
    Parent.clear

    expect_raises(Exception, "boom") do
      Parent.transaction do
        Parent.create!(name: "Outer")
        Parent.transaction { raise "boom" }
      end
    end

    Parent.count.should eq(0)
  end

  it "opens a savepoint for a plain nested block under a joinable: false parent" do
    Parent.clear

    statements = TransactionSqlRecorder.record do
      Parent.transaction(joinable: false) do
        Parent.create!(name: "Outer")
        Parent.transaction do
          Parent.create!(name: "Inner")
          raise Grant::Transaction::Rollback.new
        end
      end
    end

    statements.should contain("SAVEPOINT sp_1")
    statements.any?(&.starts_with?("ROLLBACK TO SAVEPOINT")).should be_true
    Parent.all.map(&.name).should eq(["Outer"])
  end

  it "applies joinable: false to a savepoint level" do
    Parent.clear

    Parent.transaction do
      Parent.transaction(requires_new: true, joinable: false) do
        Parent.transaction do
          Parent.create!(name: "Discarded")
          raise Grant::Transaction::Rollback.new
        end
        Parent.count.should eq(0)
      end
      # Back at the joinable outer level: plain blocks join again.
      Parent.transaction do
        Parent.create!(name: "Kept")
        raise Grant::Transaction::Rollback.new
      end
    end

    Parent.all.map(&.name).should eq(["Kept"])
  end
end
