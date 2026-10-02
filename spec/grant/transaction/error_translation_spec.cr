require "../../spec_helper"

# Proves the error taxonomy (G01) applies inside the transaction engine (T01):
# failures raised by the statements a transaction sends, including its own
# control statements, surface as Grant::ErrorBase subclasses.
describe "Transaction error translation" do
  it "raises a StatementInvalid from a failing statement inside a savepoint and keeps the outer work" do
    Parent.clear

    Parent.transaction do
      Parent.create!(name: "Kept")
      expect_raises(Grant::StatementInvalid) do
        Parent.transaction(requires_new: true) do
          Parent.connection.execute("INSERT INTO no_such_table_for_translation_spec (x) VALUES (1)")
        end
      end
      Parent.create!(name: "After")
    end

    Parent.all.map(&.name.to_s).sort!.should eq(["After", "Kept"])
  end

  it "translates a constraint failure raised by COMMIT itself" do
    # MySQL checks every constraint per statement; nothing can fail at COMMIT.
    pending!("MySQL has no deferred constraints") if CURRENT_ADAPTER == "mysql"
    Parent.connection.execute("DROP TABLE IF EXISTS deferred_translation_children")
    Parent.connection.execute("DROP TABLE IF EXISTS deferred_translation_owners")
    Parent.connection.execute("CREATE TABLE deferred_translation_owners (id INTEGER PRIMARY KEY)")
    Parent.connection.execute(<<-SQL)
      CREATE TABLE deferred_translation_children (
        owner_id INTEGER REFERENCES deferred_translation_owners (id) DEFERRABLE INITIALLY DEFERRED
      )
      SQL

    # The deferred foreign key is only checked when COMMIT runs.
    error = expect_raises(Grant::InvalidForeignKey) do
      Parent.transaction do
        Parent.connection.execute("INSERT INTO deferred_translation_children (owner_id) VALUES (42)")
      end
    end
    error.sql.should eq("COMMIT")
    Grant::Transaction.current_state?.should be_nil
  ensure
    Parent.connection.execute("DROP TABLE IF EXISTS deferred_translation_children")
    Parent.connection.execute("DROP TABLE IF EXISTS deferred_translation_owners")
  end

  it "raises Transaction::ReadOnlyError for a write inside a read-only transaction" do
    unless Parent.adapter.postgres?
      pending!("PostgreSQL only: SQLite has no read-only transactions")
    end
    Parent.clear

    expect_raises(Grant::Transaction::ReadOnlyError) do
      Parent.transaction(readonly: true) do
        Parent.connection.execute("INSERT INTO parents (name) VALUES ('Rejected')")
      end
    end

    Parent.count.should eq(0)
  end

  it "raises SerializationFailure when a serializable transaction loses a write-skew race" do
    unless Parent.adapter.postgres?
      pending!("PostgreSQL only")
    end
    Parent.clear

    second_read = Channel(Nil).new(1)
    first_committed = Channel(Nil).new
    outcomes = Channel(Exception?).new(2)
    serializable = Grant::Transaction::IsolationLevel::Serializable

    spawn do
      outcome = begin
        Parent.transaction(isolation: serializable) do
          Parent.where(name: "skew").count
          second_read.receive
          Parent.connection.execute("INSERT INTO parents (name) VALUES ('first')")
        end
        nil
      rescue ex
        ex
      ensure
        first_committed.send(nil)
      end
      outcomes.send(outcome)
    end

    spawn do
      outcome = begin
        Parent.transaction(isolation: serializable) do
          Parent.where(name: "first").count
          second_read.send(nil)
          first_committed.receive
          Parent.connection.execute("INSERT INTO parents (name) VALUES ('skew')")
        end
        nil
      rescue ex
        ex
      end
      outcomes.send(outcome)
    end

    results = [outcomes.receive, outcomes.receive]
    failure = results.compact.first?
    failure.should be_a(Grant::SerializationFailure)
    failure.should be_a(Grant::Transaction::SerializationError)
    results.compact.size.should eq(1)
  end
end
