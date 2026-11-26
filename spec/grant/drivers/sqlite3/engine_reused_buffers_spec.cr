require "spec"
require "../../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"

private alias Engine = Grant::SQLite3::Engine

# An in-memory database on Grant's engine.
private def open_engine_database : Engine::Database
  code, database = Engine::GrantEngine.new.open(":memory:")
  code.should eq(Engine::OK_CODE)
  database
end

# Prepares *sql*, steps it to the end and finalizes it, returning the last
# step's code.
private def run_statement(database : Engine::Database, sql : String) : Int32
  code, statement = database.prepare(sql)
  code.should eq(Engine::OK_CODE)
  step_code = statement.step
  while step_code == Engine::ROW_CODE
    step_code = statement.step
  end
  statement.finalize_statement
  step_code
end

# Every row of *sql*, each column read as text.
private def rows_of(database : Engine::Database, sql : String) : Array(Array(String))
  code, statement = database.prepare(sql)
  code.should eq(Engine::OK_CODE)
  rows = [] of Array(String)
  while statement.step == Engine::ROW_CODE
    rows << (0...statement.column_count).map { |column| statement.column_text(column) }
  end
  statement.finalize_statement
  rows
end

describe Engine::GrantEngine do
  describe "savepoint statements prepared again after a finalize" do
    it "keeps each savepoint's own name through nested savepoints, a rollback and releases" do
      database = open_engine_database
      database.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)").should eq(Engine::OK_CODE)
      database.exec("BEGIN").should eq(Engine::OK_CODE)
      run_statement(database, "SAVEPOINT outer_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "INSERT INTO notes (body) VALUES ('kept')").should eq(Engine::DONE_CODE)
      run_statement(database, "SAVEPOINT inner_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "INSERT INTO notes (body) VALUES ('undone')").should eq(Engine::DONE_CODE)
      run_statement(database, "ROLLBACK TO inner_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "RELEASE inner_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "RELEASE SAVEPOINT outer_mark").should eq(Engine::DONE_CODE)
      database.exec("COMMIT").should eq(Engine::OK_CODE)
      rows_of(database, "SELECT body FROM notes ORDER BY id").should eq([["kept"]])
      database.close.should eq(Engine::OK_CODE)
    end

    it "reports a savepoint that was released before its statement came back" do
      database = open_engine_database
      database.exec("BEGIN").should eq(Engine::OK_CODE)
      run_statement(database, "SAVEPOINT first_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "RELEASE first_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "RELEASE first_mark").should eq(Engine::ERROR_CODE)
      database.error_message.should eq("no such savepoint: first_mark")
      database.exec("COMMIT").should eq(Engine::OK_CODE)
      database.close.should eq(Engine::OK_CODE)
    end

    it "refuses a finalized statement and leaves the statement that took over its query alone" do
      database = open_engine_database
      database.exec("BEGIN").should eq(Engine::OK_CODE)
      _, finished = database.prepare("SAVEPOINT finished_mark")
      finished.step.should eq(Engine::DONE_CODE)
      finished.finalize_statement.should eq(Engine::OK_CODE)
      _, current = database.prepare("SAVEPOINT current_mark")
      finished.step.should eq(Engine::MISUSE_CODE)
      finished.reset.should eq(Engine::MISUSE_CODE)
      finished.finalize_statement.should eq(Engine::OK_CODE)
      current.step.should eq(Engine::DONE_CODE)
      current.finalize_statement.should eq(Engine::OK_CODE)
      run_statement(database, "RELEASE current_mark").should eq(Engine::DONE_CODE)
      run_statement(database, "RELEASE finished_mark").should eq(Engine::DONE_CODE)
      database.exec("COMMIT").should eq(Engine::OK_CODE)
      database.close.should eq(Engine::OK_CODE)
    end
  end

  describe "INSERT rows built in reused arrays" do
    it "writes each run of one prepared single-row INSERT with its own values and index entries" do
      database = open_engine_database
      database.exec("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, team TEXT DEFAULT 'none'); " \
                    "CREATE INDEX people_age ON people (age); CREATE INDEX people_team_name ON people (team, name) WHERE age > 30").should eq(Engine::OK_CODE)
      _, insert = database.prepare("INSERT INTO people (name, age) VALUES (?, ?)")
      [{"Ada", 36_i64}, {"Brook", 25_i64}, {"Cyd", 41_i64}].each do |name, age|
        insert.reset
        insert.bind_text(1, name)
        insert.bind_int64(2, age)
        insert.step.should eq(Engine::DONE_CODE)
      end
      insert.finalize_statement
      rows_of(database, "SELECT id, name, age, team FROM people ORDER BY id").should eq(
        [["1", "Ada", "36", "none"], ["2", "Brook", "25", "none"], ["3", "Cyd", "41", "none"]])
      rows_of(database, "SELECT name FROM people WHERE age > 30 AND team = 'none' ORDER BY name").should eq([["Ada"], ["Cyd"]])
      rows_of(database, "SELECT name FROM people INDEXED BY people_age WHERE age BETWEEN 20 AND 40 ORDER BY age").should eq([["Brook"], ["Ada"]])
      rows_of(database, "PRAGMA integrity_check").should eq([["ok"]])
      database.close.should eq(Engine::OK_CODE)
    end

    it "keeps every row of a multi-row VALUES distinct" do
      database = open_engine_database
      database.exec("CREATE TABLE pairs (a INTEGER, b TEXT); INSERT INTO pairs VALUES (1, 'one'), (2, 'two'), (3, 'three')").should eq(Engine::OK_CODE)
      rows_of(database, "SELECT a, b FROM pairs ORDER BY a").should eq([["1", "one"], ["2", "two"], ["3", "three"]])
      database.close.should eq(Engine::OK_CODE)
    end

    it "builds a row of its own for an INSERT a trigger runs while the outer row is being written" do
      database = open_engine_database
      database.exec("PRAGMA recursive_triggers = ON; CREATE TABLE chain (id INTEGER PRIMARY KEY, depth INTEGER, label TEXT); " \
                    "CREATE TRIGGER chain_more BEFORE INSERT ON chain WHEN NEW.depth < 3 " \
                    "BEGIN INSERT INTO chain (depth, label) VALUES (NEW.depth + 1, 'from ' || NEW.label); END").should eq(Engine::OK_CODE)
      run_statement(database, "INSERT INTO chain (depth, label) VALUES (1, 'top')").should eq(Engine::DONE_CODE)
      rows_of(database, "SELECT depth, label FROM chain ORDER BY depth").should eq(
        [["1", "top"], ["2", "from top"], ["3", "from from top"]])
      database.close.should eq(Engine::OK_CODE)
    end
  end
end
