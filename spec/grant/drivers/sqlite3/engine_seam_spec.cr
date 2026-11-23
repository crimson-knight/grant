{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "../../../spec_helper"

# Opens a driver connection to a fresh database file of its own, runs the
# block and removes the file.
private def with_seam_connection(&)
  path = File.tempname("grant_engine_seam", ".sqlite3")
  connection = DB.connect("sqlite3:#{path}")
  begin
    yield connection.as(Grant::SQLite3::Connection)
  ensure
    connection.close
    File.delete(path) if File.exists?(path)
  end
end

describe "Grant::SQLite3 engine seam" do
  it "uses the C library by default" do
    Grant::Settings.new.sqlite_engine.should eq :libsqlite3

    with_seam_connection do |connection|
      if GRANT_SQLITE_ENGINE == :grant
        connection.engine_database.should be_a(Grant::SQLite3::Engine::GrantEngine::Database)
      else
        connection.engine_database.should be_a(Grant::SQLite3::Engine::LibSQLite3Engine::Database)
      end
      connection.scalar("SELECT 1 + 1").should eq 2
    end
  end

  it "rejects an engine it does not know" do
    expect_raises(ArgumentError, "sqlite_engine must be :libsqlite3 or :grant (got :postgres)") do
      Grant.settings.sqlite_engine = :postgres
    end
    Grant.settings.sqlite_engine.should eq GRANT_SQLITE_ENGINE
  end

  it "reads and writes a database C SQLite wrote with Grant's engine" do
    path = File.tempname("grant_engine_seam_grant", ".sqlite3")
    Grant.settings.sqlite_engine = :libsqlite3
    DB.open("sqlite3:#{path}") do |db|
      db.exec "CREATE TABLE fruits (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO fruits (name) VALUES ('apple')"
      db.exec "INSERT INTO fruits (name) VALUES ('pear')"
    end

    Grant.settings.sqlite_engine = :grant
    connection = DB.connect("sqlite3:#{path}").as(Grant::SQLite3::Connection)
    begin
      engine_database = connection.engine_database
      engine_database.should be_a(Grant::SQLite3::Engine::GrantEngine::Database)
      if engine_database.is_a?(Grant::SQLite3::Engine::GrantEngine::Database)
        fruits = engine_database.engine_database.schema.table_definition("fruits")
        fruits.list_of_columns.map(&.column_name).should eq ["id", "name"]
      end

      connection.query_all("SELECT name FROM fruits ORDER BY id", as: String).should eq ["apple", "pear"]
      connection.query_all("SELECT id, upper(name) FROM fruits WHERE name LIKE ?", "p%", as: {Int64, String}).should eq [{2_i64, "PEAR"}]
      connection.scalar("SELECT count(*) FROM fruits").should eq 2
      connection.scalar("SELECT avg(id) FROM fruits").should eq 1.5
      connection.scalar("SELECT max(name) FROM fruits").should eq "pear"
      connection.scalar("SELECT NULL").should be_nil
      expect_raises(Grant::SQLite3::Exception, "no such column: weight") do
        connection.query_all("SELECT weight FROM fruits", as: Int64)
      end
      connection.exec("INSERT INTO fruits (name) VALUES ('fig')").last_insert_id.should eq 3
    ensure
      connection.close
    end

    Grant.settings.sqlite_engine = :libsqlite3
    begin
      DB.open("sqlite3:#{path}") do |db|
        db.query_all("SELECT name FROM fruits ORDER BY id", as: String).should eq ["apple", "pear", "fig"]
        db.scalar("PRAGMA integrity_check").should eq "ok"
      end
    ensure
      Grant.settings.sqlite_engine = GRANT_SQLITE_ENGINE
      File.delete(path) if File.exists?(path)
    end
  end

  it "sees what another connection to the same file committed, and lets deferred transactions read side by side" do
    path = File.tempname("grant_engine_seam_two", ".sqlite3")
    Grant.settings.sqlite_engine = :grant
    first = DB.connect("sqlite3:#{path}?journal_mode=delete").as(Grant::SQLite3::Connection)
    second = DB.connect("sqlite3:#{path}?journal_mode=delete").as(Grant::SQLite3::Connection)
    begin
      first.exec "CREATE TABLE counters (id INTEGER PRIMARY KEY, label TEXT)"
      first.exec "INSERT INTO counters (label) VALUES ('before')"
      second.scalar("SELECT label FROM counters WHERE id = 1").should eq "before"
      first.exec "UPDATE counters SET label = 'after' WHERE id = 1"
      second.scalar("SELECT label FROM counters WHERE id = 1").should eq "after"
      first.exec "ALTER TABLE counters ADD COLUMN amount INTEGER DEFAULT 7"
      second.scalar("SELECT amount FROM counters WHERE id = 1").should eq 7

      first.exec "BEGIN"
      second.exec "BEGIN"
      first.scalar("SELECT count(*) FROM counters").should eq 1
      second.scalar("SELECT count(*) FROM counters").should eq 1
      second.exec "COMMIT"
      first.exec "INSERT INTO counters (label) VALUES ('inside')"
      first.exec "COMMIT"
      second.scalar("SELECT count(*) FROM counters").should eq 2
    ensure
      first.close
      second.close
      Grant.settings.sqlite_engine = GRANT_SQLITE_ENGINE
      File.delete(path) if File.exists?(path)
    end
  end

  it "writes each prepared statement to the capture IO, one per line" do
    capture = IO::Memory.new
    Grant.settings.sqlite_statement_capture = capture
    begin
      with_seam_connection do |connection|
        connection.exec "CREATE TABLE notes (id INTEGER PRIMARY KEY,\n  body TEXT)"
        connection.exec "INSERT INTO notes (body) VALUES (?)", "first"
        connection.query_all("SELECT body FROM notes WHERE id = ?", 1, as: String).should eq ["first"]
      end
    ensure
      Grant.settings.sqlite_statement_capture = GRANT_SQL_CAPTURE_IO
    end

    capture.to_s.lines.should eq [
      "CREATE TABLE notes (id INTEGER PRIMARY KEY,   body TEXT)",
      "INSERT INTO notes (body) VALUES (?)",
      "SELECT body FROM notes WHERE id = ?",
    ]
  end
end
