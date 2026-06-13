require "../../spec_helper"

describe Grant::Locking::Pessimistic do
  describe ".lock" do
    it "adds lock mode to query" do
      query = Parent.lock
      query.lock_mode.should eq(Grant::Locking::LockMode::Update)
    end

    it "accepts specific lock mode" do
      query = Parent.lock(Grant::Locking::LockMode::Share)
      query.lock_mode.should eq(Grant::Locking::LockMode::Share)
    end

    it "can be chained with where" do
      query = Parent.where(name: "Test").lock
      query.lock_mode.should eq(Grant::Locking::LockMode::Update)
      query.where_fields.size.should eq(1)
    end
  end

  describe ".with_lock" do
    it "locks a record within a transaction" do
      parent = Parent.create!(name: "Test Parent")

      Parent.with_lock(parent.id) do |locked_parent|
        locked_parent.id.should eq(parent.id)
        locked_parent.name.should eq("Test Parent")

        locked_parent.name = "Updated Parent"
        locked_parent.save!
      end

      parent.reload
      parent.name.should eq("Updated Parent")
    end

    it "rolls back changes on exception" do
      parent = Parent.create!(name: "Original Name")

      expect_raises(Exception, "Test error") do
        Parent.with_lock(parent.id) do |locked_parent|
          locked_parent.name = "Should be rolled back"
          locked_parent.save!
          raise "Test error"
        end
      end

      parent.reload
      parent.name.should eq("Original Name")
    end
  end

  describe "#with_lock" do
    it "locks instance within a transaction" do
      parent = Parent.create!(name: "Test Parent")

      parent.with_lock do |locked_parent|
        locked_parent.object_id.should eq(parent.object_id)
        locked_parent.name = "Updated via instance"
        locked_parent.save!
      end

      parent.reload
      parent.name.should eq("Updated via instance")
    end
  end

  describe "#reload_with_lock" do
    it "reloads record with lock" do
      parent = Parent.create!(name: "Original")

      Parent.transaction do
        parent.reload_with_lock
        parent.name = "Updated"
        parent.save!
      end

      Parent.find!(parent.id).name.should eq("Updated")
    end
  end

  describe "lock mode SQL generation" do
    it "generates correct SQL for different adapters" do
      pg_adapter = Grant::Adapter::Pg.new("test_pg", "postgres://localhost/test")
      mysql_adapter = Grant::Adapter::Mysql.new("test_mysql", "mysql://localhost/test")
      sqlite_adapter = Grant::Adapter::Sqlite.new("test_sqlite", "sqlite3://./test.db")

      # PostgreSQL supports all lock modes
      Grant::Locking::LockMode::Update.to_sql(pg_adapter).should eq("FOR UPDATE")
      Grant::Locking::LockMode::UpdateNoWait.to_sql(pg_adapter).should eq("FOR UPDATE NOWAIT")
      Grant::Locking::LockMode::ShareSkipLocked.to_sql(pg_adapter).should eq("FOR SHARE SKIP LOCKED")

      # MySQL has limited support
      Grant::Locking::LockMode::Update.to_sql(mysql_adapter).should eq("FOR UPDATE")
      Grant::Locking::LockMode::Share.to_sql(mysql_adapter).should eq("LOCK IN SHARE MODE")

      # SQLite doesn't support row-level locking
      Grant::Locking::LockMode::Update.to_sql(sqlite_adapter).should eq("")
    end
  end

  describe "adapter support checks" do
    it "correctly reports lock mode support" do
      case Parent.adapter
      when Grant::Adapter::Pg
        Parent.adapter.supports_lock_mode?(Grant::Locking::LockMode::UpdateNoWait).should be_true
      when Grant::Adapter::Mysql
        Parent.adapter.supports_lock_mode?(Grant::Locking::LockMode::Update).should be_true
        Parent.adapter.supports_lock_mode?(Grant::Locking::LockMode::ShareNoWait).should be_false
      when Grant::Adapter::Sqlite
        Parent.adapter.supports_lock_mode?(Grant::Locking::LockMode::Update).should be_false
      end
    end
  end

  # Regression coverage for issue #40: LockMode#to_sql must dispatch to the
  # adapter (#lock_clause) instead of `case`ing over adapter class literals,
  # so a single-adapter app compiles without requiring all three shards.
  describe "#lock_clause adapter dispatch (issue #40)" do
    it "delegates LockMode#to_sql to the adapter's #lock_clause" do
      sqlite_adapter = Grant::Adapter::Sqlite.new("test_sqlite", "sqlite3::memory:")
      # to_sql on an adapter must equal lock_clause on that same adapter.
      Grant::Locking::LockMode::Update.to_sql(sqlite_adapter)
        .should eq(sqlite_adapter.lock_clause(Grant::Locking::LockMode::Update))
    end

    it "preserves PostgreSQL lock SQL via #lock_clause" do
      pg = Grant::Adapter::Pg.new("test_pg", "postgres://localhost/test")
      pg.lock_clause(Grant::Locking::LockMode::Update).should eq("FOR UPDATE")
      pg.lock_clause(Grant::Locking::LockMode::Share).should eq("FOR SHARE")
      pg.lock_clause(Grant::Locking::LockMode::UpdateNoWait).should eq("FOR UPDATE NOWAIT")
      pg.lock_clause(Grant::Locking::LockMode::UpdateSkipLocked).should eq("FOR UPDATE SKIP LOCKED")
      pg.lock_clause(Grant::Locking::LockMode::ShareNoWait).should eq("FOR SHARE NOWAIT")
      pg.lock_clause(Grant::Locking::LockMode::ShareSkipLocked).should eq("FOR SHARE SKIP LOCKED")
    end

    it "preserves MySQL lock SQL via #lock_clause" do
      mysql = Grant::Adapter::Mysql.new("test_mysql", "mysql://localhost/test")
      mysql.lock_clause(Grant::Locking::LockMode::Update).should eq("FOR UPDATE")
      mysql.lock_clause(Grant::Locking::LockMode::Share).should eq("LOCK IN SHARE MODE")
      mysql.lock_clause(Grant::Locking::LockMode::UpdateNoWait).should eq("FOR UPDATE NOWAIT")
      mysql.lock_clause(Grant::Locking::LockMode::UpdateSkipLocked).should eq("FOR UPDATE SKIP LOCKED")
    end

    it "raises for MySQL lock modes it cannot express" do
      mysql = Grant::Adapter::Mysql.new("test_mysql", "mysql://localhost/test")
      expect_raises(Grant::Locking::LockNotAvailableError) do
        mysql.lock_clause(Grant::Locking::LockMode::ShareNoWait)
      end
    end

    it "treats SQLite locking as a no-op (empty clause)" do
      sqlite = Grant::Adapter::Sqlite.new("test_sqlite", "sqlite3::memory:")
      sqlite.lock_clause(Grant::Locking::LockMode::Update).should eq("")
      sqlite.lock_clause(Grant::Locking::LockMode::Share).should eq("")
    end
  end
end
