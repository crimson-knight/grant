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
      connection.engine_database.should be_a(Grant::SQLite3::Engine::LibSQLite3Engine::Database)
      connection.scalar("SELECT 1 + 1").should eq 2
    end
  end

  it "rejects an engine it does not know" do
    expect_raises(ArgumentError, "sqlite_engine must be :libsqlite3 or :grant (got :postgres)") do
      Grant.settings.sqlite_engine = :postgres
    end
    Grant.settings.sqlite_engine.should eq :libsqlite3
  end

  it "opens a database with Grant's engine and reports statements as unsupported until milestone G4" do
    path = File.tempname("grant_engine_seam_grant", ".sqlite3")
    DB.open("sqlite3:#{path}") do |db|
      db.exec "CREATE TABLE fruits (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO fruits (name) VALUES ('apple')"
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

      expect_raises(Grant::SQLiteEngine::UnsupportedSQL, /milestone G4: SELECT name FROM fruits/) do
        connection.query_all("SELECT name FROM fruits", as: String)
      end
    ensure
      connection.close
      Grant.settings.sqlite_engine = :libsqlite3
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
