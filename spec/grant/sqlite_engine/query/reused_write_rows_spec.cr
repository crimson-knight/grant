require "spec"
require "../../../support/sqlite_engine/write_oracle"

# UPDATE and DELETE plans keep the arrays they read target rows into from
# run to run, and the target scan lends its result row. These run one
# prepared statement many times, with RETURNING over several rows, and with
# recursive triggers that run the same trigger plan inside itself.
module ReusedWriteRowsSpecFixture
  alias V = Grant::SQLiteEngine::Value

  # One row of values, typed as the engine returns it.
  def self.row(*values) : Array(V)
    list = [] of V
    values.each { |value| list << value }
    list
  end

  def self.in_memory_session : Grant::SQLiteEngine::Query::Session
    pager = Grant::SQLiteEngine::Pager.open_read_write(Grant::SQLiteEngine::MemoryFileSystem.new, ":memory:")
    Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.new(pager))
  end

  def self.execute(session : Grant::SQLiteEngine::Query::Session, sql : String) : Array(Array(V))
    query = session.prepare(sql)
    rows = [] of Array(V)
    while query.step
      rows << query.row.dup
    end
    rows
  end

  # Runs *query* again with *parameters* and returns its rows.
  def self.rerun(query : Grant::SQLiteEngine::Query::PreparedQuery, parameters : Array(V)) : Array(Array(V))
    query.reset
    parameters.each_with_index { |value, index| query.bind(index + 1, value) }
    rows = [] of Array(V)
    while query.step
      rows << query.row.dup
    end
    rows
  end

  def self.people_session : Grant::SQLiteEngine::Query::Session
    session = in_memory_session
    execute(session, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, score REAL)")
    execute(session, "CREATE INDEX people_age ON people (age)")
    execute(session, "INSERT INTO people (name, age, score) VALUES ('Ada', 36, 1.5), ('Bob', 17, 2.5), ('Cy', 40, 3.5), ('Di', 17, 4.5)")
    session
  end

  def self.run_pair(name : String, statements : Array(String)) : Array(String)
    directory = File.join(Dir.tempdir, "grant-reused-rows-spec-#{Process.pid}")
    pair = SQLiteWriteOracle::Pair.new(directory, name.gsub(/\W/, "_"))
    failures = [] of String
    begin
      statements.each do |sql|
        if difference = pair.step(sql)
          failures << "#{sql}\n    #{difference}"
        end
      end
      if difference = pair.file_difference
        failures << "after the scenario: #{difference}"
      end
    ensure
      pair.close
      FileUtils.rm_rf(directory)
    end
    failures
  end
end

describe "Grant::SQLiteEngine::Query UPDATE and DELETE with reused row arrays" do
  it "reads each row afresh when one prepared UPDATE runs again and again" do
    session = ReusedWriteRowsSpecFixture.people_session
    update = session.prepare("UPDATE people SET score = ?, name = name || ? WHERE id = ?")
    [{1_i64, 10.0, "!"}, {2_i64, 20.0, "?"}, {1_i64, 11.0, "+"}, {4_i64, 40.0, "#"}].each do |id, score, suffix|
      ReusedWriteRowsSpecFixture.rerun(update, [score, suffix, id] of ReusedWriteRowsSpecFixture::V)
    end
    ReusedWriteRowsSpecFixture.execute(session, "SELECT id, name, age, score FROM people ORDER BY id").should eq([
      ReusedWriteRowsSpecFixture.row(1_i64, "Ada!+", 36_i64, 11.0),
      ReusedWriteRowsSpecFixture.row(2_i64, "Bob?", 17_i64, 20.0),
      ReusedWriteRowsSpecFixture.row(3_i64, "Cy", 40_i64, 3.5),
      ReusedWriteRowsSpecFixture.row(4_i64, "Di#", 17_i64, 40.0),
    ] of Array(ReusedWriteRowsSpecFixture::V))
    ReusedWriteRowsSpecFixture.execute(session, "PRAGMA integrity_check").should eq([ReusedWriteRowsSpecFixture.row("ok")])
  end

  it "returns each row's own values when one UPDATE ... RETURNING changes several rows, run after run" do
    session = ReusedWriteRowsSpecFixture.people_session
    update = session.prepare("UPDATE people SET age = age + ?, score = id * ? WHERE age < 38 RETURNING id, name, age, score")
    first = ReusedWriteRowsSpecFixture.rerun(update, [1_i64, 10.0] of ReusedWriteRowsSpecFixture::V)
    first.sort_by(&.[0].as(Int64)).should eq([
      ReusedWriteRowsSpecFixture.row(1_i64, "Ada", 37_i64, 10.0),
      ReusedWriteRowsSpecFixture.row(2_i64, "Bob", 18_i64, 20.0),
      ReusedWriteRowsSpecFixture.row(4_i64, "Di", 18_i64, 40.0),
    ] of Array(ReusedWriteRowsSpecFixture::V))
    second = ReusedWriteRowsSpecFixture.rerun(update, [1_i64, 100.0] of ReusedWriteRowsSpecFixture::V)
    second.sort_by(&.[0].as(Int64)).should eq([
      ReusedWriteRowsSpecFixture.row(1_i64, "Ada", 38_i64, 100.0),
      ReusedWriteRowsSpecFixture.row(2_i64, "Bob", 19_i64, 200.0),
      ReusedWriteRowsSpecFixture.row(4_i64, "Di", 19_i64, 400.0),
    ] of Array(ReusedWriteRowsSpecFixture::V))
    ReusedWriteRowsSpecFixture.execute(session, "SELECT count(*) FROM people WHERE age = 19").should eq([ReusedWriteRowsSpecFixture.row(2_i64)])
    ReusedWriteRowsSpecFixture.execute(session, "PRAGMA integrity_check").should eq([ReusedWriteRowsSpecFixture.row("ok")])
  end

  it "returns each run's deleted rows when one DELETE ... RETURNING runs again" do
    session = ReusedWriteRowsSpecFixture.people_session
    delete = session.prepare("DELETE FROM people WHERE age = ? RETURNING id, name, score")
    ReusedWriteRowsSpecFixture.rerun(delete, [17_i64] of ReusedWriteRowsSpecFixture::V).sort_by(&.[0].as(Int64)).should eq([
      ReusedWriteRowsSpecFixture.row(2_i64, "Bob", 2.5),
      ReusedWriteRowsSpecFixture.row(4_i64, "Di", 4.5),
    ] of Array(ReusedWriteRowsSpecFixture::V))
    ReusedWriteRowsSpecFixture.rerun(delete, [36_i64] of ReusedWriteRowsSpecFixture::V).should eq([
      ReusedWriteRowsSpecFixture.row(1_i64, "Ada", 1.5),
    ] of Array(ReusedWriteRowsSpecFixture::V))
    ReusedWriteRowsSpecFixture.rerun(delete, [17_i64] of ReusedWriteRowsSpecFixture::V).should eq([] of Array(ReusedWriteRowsSpecFixture::V))
    ReusedWriteRowsSpecFixture.execute(session, "SELECT id, name FROM people").should eq([ReusedWriteRowsSpecFixture.row(3_i64, "Cy")])
    ReusedWriteRowsSpecFixture.execute(session, "PRAGMA integrity_check").should eq([ReusedWriteRowsSpecFixture.row("ok")])
  end

  it "matches C SQLite when recursive triggers run an UPDATE or DELETE plan inside itself" do
    failures = ReusedWriteRowsSpecFixture.run_pair("recursive triggers", [
      "PRAGMA recursive_triggers = ON",
      "CREATE TABLE chain (id INTEGER PRIMARY KEY, depth INTEGER, label TEXT, note TEXT)",
      "CREATE INDEX chain_depth ON chain (depth)",
      "CREATE TABLE log (seq INTEGER PRIMARY KEY, id INTEGER, old_depth INTEGER, new_depth INTEGER, old_label TEXT, new_label TEXT)",
      "CREATE TRIGGER chain_up AFTER UPDATE OF depth ON chain WHEN new.depth < 5 BEGIN " \
      "INSERT INTO log (id, old_depth, new_depth, old_label, new_label) VALUES (old.id, old.depth, new.depth, old.label, new.label); " \
      "UPDATE chain SET depth = depth + 1, label = label || '.' WHERE id = new.id; END",
      "CREATE TRIGGER chain_gone BEFORE DELETE ON chain BEGIN " \
      "INSERT INTO log (id, old_depth, old_label) VALUES (old.id, old.depth, old.label); " \
      "DELETE FROM chain WHERE id = old.id + 1; END",
      "INSERT INTO chain (id, depth, label, note) VALUES (1, 0, 'a', 'one'), (2, 0, 'b', 'two'), (3, 2, 'c', 'three'), (11, 0, 'k', 'eleven'), (12, 1, 'l', 'twelve')",
      "UPDATE chain SET depth = depth + 1 WHERE id IN (1, 2) RETURNING id, depth, label, note",
      "SELECT * FROM chain ORDER BY id",
      "SELECT * FROM log ORDER BY seq",
      "DELETE FROM chain WHERE id = 1 RETURNING id, depth, label",
      "SELECT * FROM chain ORDER BY id",
      "SELECT * FROM log ORDER BY seq",
      "PRAGMA integrity_check",
    ])
    failures.should eq([] of String)
  end
end
