require "../../spec_helper"
require "./sql_recorder"

private def statements_for(adapter : Grant::Adapter::Base, **options) : Array(String)
  Grant::Transaction.begin_statements(adapter, Grant::Transaction::Options.new(**options))
end

describe "Transaction isolation SQL" do
  pg = Grant::Adapter::Pg.new(name: "sql_only_pg", url: "postgres://localhost/unused")
  mysql = Grant::Adapter::Mysql.new(name: "sql_only_mysql", url: "mysql://localhost/unused")
  sqlite = Grant::Adapter::Sqlite.new(name: "sql_only_sqlite", url: "sqlite3://./unused_isolation.db")

  describe "PostgreSQL" do
    it "puts the level and access mode in BEGIN" do
      statements_for(pg).should eq(["BEGIN READ WRITE"])
      statements_for(pg, readonly: true).should eq(["BEGIN READ ONLY"])
      statements_for(pg, isolation: Grant::Transaction::IsolationLevel::Serializable).should eq(["BEGIN ISOLATION LEVEL SERIALIZABLE READ WRITE"])
      statements_for(pg, isolation: Grant::Transaction::IsolationLevel::RepeatableRead, readonly: true).should eq(["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"])
    end
  end

  describe "MySQL" do
    it "sets the level before START TRANSACTION" do
      statements_for(mysql).should eq(["START TRANSACTION"])
      statements_for(mysql, readonly: true).should eq(["START TRANSACTION READ ONLY"])
      statements_for(mysql, isolation: Grant::Transaction::IsolationLevel::ReadCommitted).should eq([
        "SET TRANSACTION ISOLATION LEVEL READ COMMITTED",
        "START TRANSACTION",
      ])
    end
  end

  describe "SQLite" do
    it "maps levels onto BEGIN variants" do
      statements_for(sqlite).should eq(["BEGIN"])
      statements_for(sqlite, isolation: Grant::Transaction::IsolationLevel::ReadUncommitted).should eq(["BEGIN DEFERRED"])
      statements_for(sqlite, isolation: Grant::Transaction::IsolationLevel::ReadCommitted).should eq(["BEGIN IMMEDIATE"])
      statements_for(sqlite, isolation: Grant::Transaction::IsolationLevel::RepeatableRead).should eq(["BEGIN IMMEDIATE"])
      statements_for(sqlite, isolation: Grant::Transaction::IsolationLevel::Serializable).should eq(["BEGIN EXCLUSIVE"])
    end
  end

  it "sends the statements built for the active adapter when a transaction opens" do
    adapter = Parent.adapter
    expected = Grant::Transaction.begin_statements(adapter, Grant::Transaction::Options.new(isolation: Grant::Transaction::IsolationLevel::Serializable))

    statements = TransactionSqlRecorder.record do
      Parent.transaction(isolation: Grant::Transaction::IsolationLevel::Serializable) { }
    end

    statements.should eq(expected + ["COMMIT"])
  end

  describe "nested isolation" do
    it "raises TransactionIsolationError for a joined block" do
      expect_raises(Grant::TransactionIsolationError) do
        Parent.transaction do
          Parent.transaction(isolation: Grant::Transaction::IsolationLevel::Serializable) { }
        end
      end
    end

    it "raises TransactionIsolationError for a savepoint block" do
      expect_raises(Grant::TransactionIsolationError) do
        Parent.transaction do
          Parent.transaction(isolation: Grant::Transaction::IsolationLevel::ReadCommitted, requires_new: true) { }
        end
      end
    end

    it "leaves the outer transaction usable when the caller rescues the error" do
      Parent.clear

      Parent.transaction do
        Parent.create!(name: "Outer")
        begin
          Parent.transaction(isolation: Grant::Transaction::IsolationLevel::Serializable) { }
        rescue Grant::TransactionIsolationError
        end
      end

      Parent.count.should eq(1)
    end

    it "allows an isolation level on an independent transaction" do
      Parent.transaction do
        Parent.transaction(isolation: Grant::Transaction::IsolationLevel::ReadCommitted, independent: true) { 1 }.should eq(1)
      end
    end

    it "is an ErrorBase" do
      Grant::TransactionIsolationError.new.should be_a(Grant::ErrorBase)
    end
  end
end
