require "spec"
require "../../../support/sqlite_engine/trigger_differential"

# Recursive triggers on Grant's engine against C SQLite 3.51.0 (issue #145):
# UPDATE triggers whose body updates the firing row and the rows 10, 20, ...
# ids above it, DELETE triggers that delete or insert further rows, BEFORE
# and AFTER, recursive_triggers on and off, and recursion that reaches and
# passes SQLITE_MAX_TRIGGER_DEPTH. Every statement's rows, error,
# changes() and total_changes() are compared, then both files.
module RecursiveTriggerDifferentialFixture
  @[Link("sqlite3")]
  lib LibResultCode
    fun extended_errcode = sqlite3_extended_errcode(database : SQLiteSQLOracle::LibOracle::Database) : Int32
  end

  # The ids of *count* rows: 1, 11, 21, ...
  def self.list_of_ids(count : Int32) : Array(Int32)
    (0...count).map { |index| 1 + index * 10 }
  end

  def self.recursion_pragma(recursive : Bool) : String
    "PRAGMA recursive_triggers = #{recursive ? "ON" : "OFF"}"
  end

  # The shape of #145: each UPDATE of a row updates it and the *count* - 1
  # rows 10, 20, ... ids above it, while n is below 8.
  def self.update_fan_out(count : Int32, time : String, recursive : Bool) : TriggerScenario
    matches = (0...count).map { |index| index == 0 ? "id = new.id" : "id = new.id + #{index * 10}" }.join(" OR ")
    values = list_of_ids(count).map { |id| "(#{id}, 0)" }.join(", ")
    TriggerScenario.new("#{time} UPDATE over #{count} rows, recursive_triggers #{recursive ? "on" : "off"}", [
      recursion_pragma(recursive),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "INSERT INTO t VALUES #{values}",
      "CREATE TRIGGER t_fan_out #{time} UPDATE ON t BEGIN UPDATE t SET n = n + 1 WHERE (#{matches}) AND n < 8; END",
      "UPDATE t SET n = n + 1 WHERE id = 1",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "UPDATE t SET n = n % 3",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
    ])
  end

  # Each UPDATE of a row updates the rows 10 and 20 ids above it, so a
  # BEFORE trigger's recursion ends too: the chain runs out of rows.
  def self.update_fan_up(time : String, recursive : Bool) : TriggerScenario
    values = list_of_ids(5).map { |id| "(#{id}, 0)" }.join(", ")
    TriggerScenario.new("#{time} UPDATE over the 2 rows above, 5 rows, recursive_triggers #{recursive ? "on" : "off"}", [
      recursion_pragma(recursive),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "INSERT INTO t VALUES #{values}",
      "CREATE TRIGGER t_fan_up #{time} UPDATE ON t BEGIN UPDATE t SET n = n + 1 WHERE id = new.id + 10 OR id = new.id + 20; END",
      "UPDATE t SET n = n + 1 WHERE id = 1",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "UPDATE t SET n = n * 2 WHERE id < 30",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
    ])
  end

  # The same fan-out, guarded by the trigger's WHEN instead of the body's
  # WHERE.
  def self.update_fan_out_when(time : String) : TriggerScenario
    TriggerScenario.new("#{time} UPDATE over 2 rows, WHEN new.n < 8", [
      recursion_pragma(true),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "INSERT INTO t VALUES (1, 0), (11, 0)",
      "CREATE TRIGGER t_fan_out #{time} UPDATE ON t WHEN new.n < 8 BEGIN UPDATE t SET n = n + 1 WHERE id = new.id OR id = new.id + 10; END",
      "UPDATE t SET n = n + 1",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
    ])
  end

  # The SET list of a trigger-bearing UPDATE read through an alias, a WITH
  # table, a subquery over the same table and a VIRTUAL generated column.
  def self.update_set_list_forms : TriggerScenario
    TriggerScenario.new("UPDATE with triggers: the SET list reads the row as it is when written", [
      recursion_pragma(true),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL, twice INTEGER AS (n * 2) VIRTUAL)",
      "CREATE TABLE log(seq INTEGER PRIMARY KEY, id INTEGER, old_n INTEGER, new_n INTEGER)",
      "INSERT INTO t (id, n) VALUES (1, 0), (11, 0), (21, 5)",
      "CREATE TRIGGER t_log AFTER UPDATE ON t BEGIN INSERT INTO log (id, old_n, new_n) VALUES (old.id, old.n, new.n); " \
      "UPDATE t SET n = n + 1 WHERE id = new.id + 10 AND n < 4; END",
      "WITH step(size) AS (SELECT 2) UPDATE t AS x SET n = x.n + (SELECT size FROM step) WHERE id IN (1, 11)",
      "SELECT changes(), total_changes()",
      "UPDATE t SET n = (SELECT count(*) FROM t AS other WHERE other.n > t.n) + twice WHERE id < 30",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "SELECT * FROM log ORDER BY seq",
    ])
  end

  # Each DELETE of a row deletes the rows 1 and 3 ids above it.
  def self.delete_fan_out(time : String, recursive : Bool) : TriggerScenario
    values = (1..12).map { |id| "(#{id}, #{id * 10})" }.join(", ")
    TriggerScenario.new("#{time} DELETE that deletes further rows, recursive_triggers #{recursive ? "on" : "off"}", [
      recursion_pragma(recursive),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "CREATE TABLE log(seq INTEGER PRIMARY KEY, id INTEGER)",
      "INSERT INTO t VALUES #{values}",
      "CREATE TRIGGER t_fan_out #{time} DELETE ON t BEGIN INSERT INTO log (id) VALUES (old.id); " \
      "DELETE FROM t WHERE id = old.id + 1 OR id = old.id + 3; END",
      "DELETE FROM t WHERE id IN (1, 6)",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "SELECT * FROM log ORDER BY seq",
    ])
  end

  # Each DELETE of a row inserts a successor 100 ids above it and deletes
  # that one and the next row, while n is below 8.
  def self.delete_that_inserts(time : String, recursive : Bool) : TriggerScenario
    TriggerScenario.new("#{time} DELETE that inserts, recursive_triggers #{recursive ? "on" : "off"}", [
      recursion_pragma(recursive),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "CREATE TABLE log(seq INTEGER PRIMARY KEY, id INTEGER, n INTEGER)",
      "INSERT INTO t VALUES (1, 0), (2, 0), (3, 5)",
      "CREATE TRIGGER t_successor #{time} DELETE ON t WHEN old.n < 8 BEGIN INSERT INTO log (id, n) VALUES (old.id, old.n); " \
      "INSERT INTO t VALUES (old.id + 100, old.n + 1); DELETE FROM t WHERE id = old.id + 100 OR id = old.id + 1; END",
      "DELETE FROM t WHERE id = 1",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "SELECT * FROM log ORDER BY seq",
    ])
  end

  # An UPDATE trigger that recurses while n is below *limit*: 1000 reaches
  # SQLITE_MAX_TRIGGER_DEPTH, 1001 passes it.
  def self.update_depth(time : String, limit : Int32, recursive : Bool) : TriggerScenario
    TriggerScenario.new("#{time} UPDATE recursing while n < #{limit}, recursive_triggers #{recursive ? "on" : "off"}", [
      recursion_pragma(recursive),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "INSERT INTO t VALUES (1, 0), (11, 0)",
      "CREATE TRIGGER t_deep #{time} UPDATE ON t BEGIN UPDATE t SET n = n + 1 WHERE id = new.id AND n < #{limit}; END",
      "UPDATE t SET n = n + 1 WHERE id = 1",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "BEGIN",
      "INSERT INTO t VALUES (21, 0)",
      "UPDATE t SET n = n + 1 WHERE id = 11",
      "SELECT changes(), total_changes()",
      "SELECT * FROM t ORDER BY id",
      "COMMIT",
      "SELECT * FROM t ORDER BY id",
    ])
  end

  # A DELETE chain over *count* rows, each deleted row deleting the next.
  def self.delete_depth(count : Int32) : TriggerScenario
    TriggerScenario.new("AFTER DELETE chain over #{count} rows", [
      recursion_pragma(true),
      "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
      "WITH RECURSIVE c(x) AS (VALUES (1) UNION ALL SELECT x + 1 FROM c WHERE x < #{count}) INSERT INTO t SELECT x, 0 FROM c",
      "CREATE TRIGGER t_chain AFTER DELETE ON t BEGIN DELETE FROM t WHERE id = old.id + 1; END",
      "DELETE FROM t WHERE id = 1",
      "SELECT changes(), total_changes()",
      "SELECT count(*), min(id), max(id) FROM t",
    ])
  end

  def self.list_of_scenarios : Array(TriggerScenario)
    list = [] of TriggerScenario
    {"AFTER", "BEFORE"}.each do |time|
      {2, 3, 5}.each { |count| list << update_fan_out(count, time, true) }
      {2, 3}.each { |count| list << update_fan_out(count, time, false) }
      list << update_fan_out_when(time)
      {true, false}.each { |recursive| list << update_fan_up(time, recursive) }
      {true, false}.each do |recursive|
        list << delete_fan_out(time, recursive)
        list << delete_that_inserts(time, recursive)
      end
      {1000, 1001}.each { |limit| list << update_depth(time, limit, true) }
    end
    list << update_depth("AFTER", 1001, false)
    list << update_set_list_forms
    {1000, 1001}.each { |count| list << delete_depth(count) }
    list
  end

  # Runs *sql* on C and on the engine, each on a new file holding the rows
  # *setup* made, and returns each side's {result code, message}.
  def self.error_on_both(setup : Array(String), sql : String) : { {Int32, String?}, {Int32, String?} }
    directory = File.join(Dir.tempdir, "grant-recursive-trigger-codes-#{Random::Secure.hex(6)}")
    pair = SQLiteWriteOracle::Pair.new(directory, "codes")
    begin
      setup.each { |statement| pair.step(statement) }
      c_message = pair.c_step(sql).outcome.error
      c_code = c_message ? LibResultCode.extended_errcode(pair.c_connection.handle) : 0
      engine = {0, nil.as(String?)}
      begin
        query = pair.session.prepare(sql)
        while query.step
        end
      rescue error : Grant::SQLiteEngine::SQLError
        engine = {error.result_code, error.message}
      end
      { {c_code, c_message}, engine }
    ensure
      pair.close
      FileUtils.rm_rf(directory)
    end
  end
end

describe "Grant::SQLiteEngine::Query recursive triggers against C SQLite 3.51.0" do
  linked = SQLiteSQLOracle.version.split(' ').first
  if linked == "3.51.0"
    RecursiveTriggerDifferentialFixture.list_of_scenarios.each do |scenario|
      it "matches C: #{scenario.name}" do
        report = TriggerReport.new
        work = File.join(Dir.tempdir, "grant-recursive-triggers-#{Random::Secure.hex(6)}")
        begin
          TriggerDifferential.new(report, work).run(scenario)
        ensure
          FileUtils.rm_rf(work)
        end
        report.list_of_differences.should eq([] of String)
        report.list_of_unexpressed.should eq([] of String)
      end
    end

    it "fails with C's result code and message past SQLITE_MAX_TRIGGER_DEPTH" do
      setup = [
        "PRAGMA recursive_triggers = ON",
        "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
        "INSERT INTO t VALUES (1, 0)",
        "CREATE TRIGGER t_deep AFTER UPDATE ON t BEGIN UPDATE t SET n = n + 1 WHERE id = new.id; END",
      ]
      c, engine = RecursiveTriggerDifferentialFixture.error_on_both(setup, "UPDATE t SET n = n + 1")
      c.should eq({Grant::SQLiteEngine::SQLError::ERROR, "too many levels of trigger recursion"})
      engine.should eq(c)
    end
  else
    pending "matches C on recursive triggers (the linked libsqlite3 is #{linked})"
  end
end
