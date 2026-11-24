{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "../../../spec_helper"

# Opens a driver connection on *engine* to *location* (a file path or
# ":memory:").
private def dump_connection(location : String, engine : Symbol = GRANT_SQLITE_ENGINE) : Grant::SQLite3::Connection
  Grant.settings.sqlite_engine = engine
  uri = location == ":memory:" ? "sqlite3://%3Amemory%3A" : "sqlite3:#{location}"
  DB.connect(uri).as(Grant::SQLite3::Connection)
ensure
  Grant.settings.sqlite_engine = GRANT_SQLITE_ENGINE
end

# Yields a folder for database files and removes it.
private def with_dump_folder(& : String ->)
  folder = File.tempname("grant_connection_dump")
  Dir.mkdir(folder)
  begin
    yield folder
  ensure
    FileUtils.rm_rf(folder)
  end
end

private def integrity_of(path : String) : String
  output = IO::Memory.new
  Process.run("/usr/bin/sqlite3", [path, "PRAGMA integrity_check; SELECT count(*) FROM people;"], output: output, error: output)
  output.to_s.strip
end

describe "Grant::SQLite3::Connection#dump" do
  it "backs a database file up to another file" do
    with_dump_folder do |folder|
      source = dump_connection(File.join(folder, "source.db"))
      target = dump_connection(File.join(folder, "target.db"))
      begin
        source.exec "CREATE TABLE people (id INTEGER PRIMARY KEY AUTOINCREMENT, first_name TEXT, age INTEGER)"
        source.exec "CREATE INDEX index_people_on_age ON people(age)"
        source.exec "INSERT INTO people (first_name, age) VALUES ('Ada', 36), ('Brian', 40)"
        source.dump(target)
        target.query_all("SELECT first_name, age FROM people ORDER BY id", as: {String, Int64}).should eq([{"Ada", 36_i64}, {"Brian", 40_i64}])
        target.exec "INSERT INTO people (first_name, age) VALUES ('Cy', 5)"
        target.scalar("SELECT max(id) FROM people").should eq 3
      ensure
        source.close
        target.close
      end
      integrity_of(File.join(folder, "target.db")).should eq("ok\n3")
    end
  end

  it "dumps to an in-memory database, adds a row there and dumps back over the source" do
    with_dump_folder do |folder|
      source = dump_connection(File.join(folder, "source.db"))
      memory = dump_connection(":memory:")
      begin
        source.exec "CREATE TABLE people (id INTEGER PRIMARY KEY, first_name TEXT, age INTEGER)"
        source.exec "INSERT INTO people (first_name, age) VALUES ('Ada', 36)"
        source.dump(memory)
        memory.scalar("SELECT count(*) FROM people").should eq 1
        memory.exec "INSERT INTO people (first_name, age) VALUES ('Brian', 40)"
        memory.dump(source)
        source.scalar("SELECT count(*) FROM people").should eq 2
      ensure
        source.close
        memory.close
      end
      integrity_of(File.join(folder, "source.db")).should eq("ok\n2")
    end
  end

  it "dumps a database of many pages" do
    with_dump_folder do |folder|
      source = dump_connection(File.join(folder, "source.db"))
      memory = dump_connection(":memory:")
      begin
        source.exec "CREATE TABLE people (id INTEGER PRIMARY KEY, first_name TEXT, age INTEGER)"
        source.exec "BEGIN"
        20_000.times { |index| source.exec "INSERT INTO people (first_name, age) VALUES (?, ?)", "person #{index}", index }
        source.exec "COMMIT"
        source.dump(memory)
        memory.scalar("SELECT count(*) FROM people").should eq 20_000
        memory.scalar("SELECT first_name FROM people WHERE age = 19999").should eq "person 19999"
      ensure
        source.close
        memory.close
      end
    end
  end

  it "dumps between a connection on Grant's engine and one on the C library, either way" do
    with_dump_folder do |folder|
      [{:grant, :libsqlite3}, {:libsqlite3, :grant}].each do |source_engine, target_engine|
        path = File.join(folder, "#{source_engine}-to-#{target_engine}.db")
        source = dump_connection(":memory:", source_engine)
        target = dump_connection(path, target_engine)
        begin
          source.exec "CREATE TABLE people (id INTEGER PRIMARY KEY, first_name TEXT, age INTEGER)"
          source.exec "INSERT INTO people (first_name, age) VALUES ('Ada', 36), ('Brian', 40)"
          source.dump(target)
          target.scalar("SELECT count(*) FROM people").should eq 2
        ensure
          source.close
          target.close
        end
        integrity_of(path).should eq("ok\n2")
      end
    end
  end

  it "raises the target's message when the target has a transaction open" do
    with_dump_folder do |folder|
      source = dump_connection(":memory:")
      target = dump_connection(File.join(folder, "target.db"))
      begin
        source.exec "CREATE TABLE people (id INTEGER PRIMARY KEY, first_name TEXT, age INTEGER)"
        target.exec "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"
        target.exec "BEGIN"
        target.exec "INSERT INTO notes (body) VALUES ('mine')"
        expect_raises(Grant::SQLite3::Exception, "destination database is in use") { source.dump(target) }
        target.exec "COMMIT"
        target.scalar("SELECT body FROM notes").should eq "mine"
      ensure
        source.close
        target.close
      end
    end
  end
end
