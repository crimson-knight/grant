require "../../spec_helper"
require "./sql_recorder"

# A second database: its own adapter instance and pool (same URL in specs).
private def other_database : String
  "#{CURRENT_ADAPTER}_with_replica"
end

describe "Transaction nesting across databases" do
  it "routes a model back onto its own open transaction from inside another database's transaction" do
    Parent.clear

    expect_raises(Exception, "outer failure") do
      Parent.transaction do
        outer_connection = Grant::Transaction.current_connection?(Parent.adapter)
        Grant.transaction(other_database) do
          Grant::Transaction.current_connection?(Parent.adapter).should be(outer_connection)
          Parent.create!(name: "Nested")
        end
        raise "outer failure"
      end
    end

    # The row was written on the outer transaction's connection, so the outer
    # rollback undoes it.
    Parent.count.should eq(0)
  end

  it "opens a savepoint on the outer connection, not a second BEGIN" do
    statements = TransactionSqlRecorder.record do
      Parent.transaction do
        Grant.transaction(other_database) do
          Parent.transaction(requires_new: true) { }
        end
      end
    end

    # One BEGIN per database, and the nested block is a savepoint.
    TransactionSqlRecorder.begins(statements).size.should eq(2)
    statements.should contain("SAVEPOINT sp_1")
  end

  it "enlists commit callbacks with the model's own transaction" do
    events = [] of Symbol

    Parent.transaction do
      Grant.transaction(other_database) do
        Parent.transaction { Parent.current_transaction.after_commit { events << :parent_commit } }
      end
      # The other database committed; the Parent transaction has not.
      events.should be_empty
    end

    events.should eq([:parent_commit])
  end
end
