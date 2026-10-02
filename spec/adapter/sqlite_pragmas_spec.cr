require "../spec_helper"

private def temp_sqlite_path : String
  File.join(Dir.tempdir, "grant_g01_pragmas_#{Random::Secure.hex(6)}.sqlite3")
end

private def remove_sqlite_files(path : String)
  {"", "-wal", "-shm", "-journal"}.each do |suffix|
    File.delete?("#{path}#{suffix}")
  end
end

private def pragma(adapter : Grant::Adapter::Sqlite, name : String) : String
  adapter.open(&.scalar("PRAGMA #{name}").to_s)
end

describe "SQLite adapter PRAGMA defaults" do
  describe ".url_with_pragmas" do
    it "appends every default for a file URL without a query" do
      Grant::Adapter::Sqlite.url_with_pragmas("sqlite3:/tmp/app.db")
        .should eq("sqlite3:/tmp/app.db?foreign_keys=1&journal_mode=wal&busy_timeout=5000&synchronous=normal")
    end

    it "keeps explicit URL parameters and adds only the missing ones" do
      Grant::Adapter::Sqlite.url_with_pragmas("sqlite3:/tmp/app.db?busy_timeout=250&other=1")
        .should eq("sqlite3:/tmp/app.db?busy_timeout=250&other=1&foreign_keys=1&journal_mode=wal&synchronous=normal")
    end

    it "lets an explicit foreign_keys=0 win" do
      Grant::Adapter::Sqlite.url_with_pragmas("sqlite3:/tmp/app.db?foreign_keys=0")
        .should contain("foreign_keys=0")
      Grant::Adapter::Sqlite.url_with_pragmas("sqlite3:/tmp/app.db?foreign_keys=0")
        .should_not contain("foreign_keys=1")
    end

    it "applies overrides over defaults, and lets the URL win over both" do
      overrides = {"journal_mode" => "delete", "cache_size" => "-2000"}
      url = Grant::Adapter::Sqlite.url_with_pragmas("sqlite3:/tmp/app.db?synchronous=full", overrides)
      url.should contain("journal_mode=delete")
      url.should contain("cache_size=-2000")
      url.should contain("synchronous=full")
      url.should_not contain("synchronous=normal")
      url.should_not contain("journal_mode=wal")
    end

    it "only enforces foreign keys for in-memory databases" do
      url = Grant::Adapter::Sqlite.url_with_pragmas("sqlite3::memory:")
      url.should eq("sqlite3::memory:?foreign_keys=1")
    end

    it "recognizes memory databases" do
      Grant::Adapter::Sqlite.memory_url?("sqlite3::memory:").should be_true
      Grant::Adapter::Sqlite.memory_url?("sqlite3:file:x?mode=memory").should be_true
      Grant::Adapter::Sqlite.memory_url?("sqlite3:/tmp/app.db").should be_false
    end
  end

  describe "on a real database file" do
    it "applies the defaults to every connection" do
      path = temp_sqlite_path
      adapter = Grant::Adapter::Sqlite.new(name: "g01_defaults", url: "sqlite3:#{path}")
      begin
        pragma(adapter, "foreign_keys").should eq("1")
        pragma(adapter, "journal_mode").should eq("wal")
        pragma(adapter, "busy_timeout").should eq("5000")
        pragma(adapter, "synchronous").should eq("1")
      ensure
        adapter.database.close
        remove_sqlite_files(path)
      end
    end

    it "lets explicit URL parameters win" do
      path = temp_sqlite_path
      adapter = Grant::Adapter::Sqlite.new(
        name: "g01_explicit",
        url: "sqlite3:#{path}?foreign_keys=0&journal_mode=delete&busy_timeout=123&synchronous=full")
      begin
        pragma(adapter, "foreign_keys").should eq("0")
        pragma(adapter, "journal_mode").should eq("delete")
        pragma(adapter, "busy_timeout").should eq("123")
        pragma(adapter, "synchronous").should eq("2")
      ensure
        adapter.database.close
        remove_sqlite_files(path)
      end
    end

    it "accepts a pragmas override for the connection" do
      path = temp_sqlite_path
      adapter = Grant::Adapter::Sqlite.new(name: "g01_override", url: "sqlite3:#{path}", pragmas: {journal_mode: "delete", busy_timeout: 42})
      begin
        pragma(adapter, "journal_mode").should eq("delete")
        pragma(adapter, "busy_timeout").should eq("42")
        pragma(adapter, "foreign_keys").should eq("1")
      ensure
        adapter.database.close
        remove_sqlite_files(path)
      end
    end

    it "enforces declared foreign keys and reports them as InvalidForeignKey" do
      path = temp_sqlite_path
      adapter = Grant::Adapter::Sqlite.new(name: "g01_fk", url: "sqlite3:#{path}")
      begin
        adapter.open do |db|
          db.exec "CREATE TABLE g01_owners (id INTEGER PRIMARY KEY)"
          db.exec "CREATE TABLE g01_pets (id INTEGER PRIMARY KEY, owner_id INTEGER REFERENCES g01_owners(id))"
        end

        error = expect_raises(Grant::InvalidForeignKey) do
          adapter.open("INSERT INTO g01_pets (owner_id) VALUES (?)", [99]) do |db|
            db.exec "INSERT INTO g01_pets (owner_id) VALUES (?)", 99
          end
        end
        error.sql.should eq("INSERT INTO g01_pets (owner_id) VALUES (?)")
      ensure
        adapter.database.close
        remove_sqlite_files(path)
      end
    end

    it "does not enforce foreign keys when the URL turns them off" do
      path = temp_sqlite_path
      adapter = Grant::Adapter::Sqlite.new(name: "g01_fk_off", url: "sqlite3:#{path}?foreign_keys=0")
      begin
        adapter.open do |db|
          db.exec "CREATE TABLE g01_owners (id INTEGER PRIMARY KEY)"
          db.exec "CREATE TABLE g01_pets (id INTEGER PRIMARY KEY, owner_id INTEGER REFERENCES g01_owners(id))"
          db.exec "INSERT INTO g01_pets (owner_id) VALUES (99)"
        end
      ensure
        adapter.database.close
        remove_sqlite_files(path)
      end
    end

    it "waits for a busy database instead of failing at once" do
      path = temp_sqlite_path
      writer = Grant::Adapter::Sqlite.new(name: "g01_busy_writer", url: "sqlite3:#{path}")
      impatient = Grant::Adapter::Sqlite.new(name: "g01_busy_impatient", url: "sqlite3:#{path}?busy_timeout=0")
      begin
        writer.open { |db| db.exec "CREATE TABLE g01_items (id INTEGER PRIMARY KEY)" }

        writer.database.using_connection do |holder|
          holder.exec "BEGIN IMMEDIATE"
          begin
            expect_raises(Grant::LockWaitTimeout) do
              impatient.open("INSERT INTO g01_items DEFAULT VALUES") do |db|
                db.exec "INSERT INTO g01_items DEFAULT VALUES"
              end
            end
          ensure
            holder.exec "ROLLBACK"
          end
        end
      ensure
        writer.database.close
        impatient.database.close
        remove_sqlite_files(path)
      end
    end
  end
end
