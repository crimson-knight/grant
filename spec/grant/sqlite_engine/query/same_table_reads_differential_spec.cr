require "spec"
require "../../../support/sqlite_engine/trigger_differential"

# Expressions a write statement evaluates per row that read the target
# table while the statement changes it, on Grant's engine against C SQLite
# 3.51.0: RETURNING and an upsert's DO UPDATE with subqueries over the
# same table (#150), and an UPDATE whose SET list reads columns a foreign
# key action of an earlier row changed (#151). Every statement's rows,
# error, changes() and total_changes() are compared, then both files.
module SameTableReadsDifferentialFixture
  # Three rows, the start of every RETURNING and upsert scenario.
  SETUP = [
    "CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER NOT NULL)",
    "INSERT INTO t VALUES (1, 1), (2, 5), (3, 7)",
  ]

  def self.scenario(name : String, list_of_statements : Array(String)) : TriggerScenario
    TriggerScenario.new(name, SETUP + list_of_statements + ["SELECT * FROM t ORDER BY id"])
  end

  def self.list_of_returning_scenarios : Array(TriggerScenario)
    [
      scenario("UPDATE RETURNING a subquery over the same table", [
        "UPDATE t SET n = n + 1 WHERE id = 1 RETURNING id, (SELECT count(*) FROM t), (SELECT sum(n) FROM t)",
        "UPDATE t SET n = n * 2 RETURNING id, n, (SELECT sum(n) FROM t)",
      ]),
      scenario("UPDATE RETURNING through an alias, with a correlated subquery", [
        "UPDATE t AS x SET n = n + 1 WHERE id < 3 RETURNING x.n, (SELECT max(n) FROM t), (SELECT count(*) FROM t AS o WHERE o.n > x.n)",
      ]),
      scenario("INSERT RETURNING a subquery over the same table", [
        "INSERT INTO t VALUES (4, 9), (5, 2) RETURNING id, (SELECT count(*) FROM t), (SELECT sum(n) FROM t)",
        "INSERT INTO t AS a VALUES (6, 3) RETURNING a.n, (SELECT max(id) FROM t), (SELECT count(*) FROM t AS o WHERE o.n > a.n)",
      ]),
      scenario("DELETE RETURNING a subquery over the same table", [
        "DELETE FROM t WHERE id > 1 RETURNING id, (SELECT count(*) FROM t), (SELECT sum(n) FROM t)",
      ]),
      scenario("DELETE RETURNING through an alias", [
        "DELETE FROM t AS d WHERE id < 3 RETURNING d.id, (SELECT count(*) FROM t AS o WHERE o.n > d.n)",
      ]),
    ]
  end

  # RETURNING beside AFTER triggers that log each row: a row is returned
  # after it is written and before its AFTER triggers run; a subquery over
  # another table is computed once per statement, one whose own FROM names
  # the table written once per row.
  def self.list_of_returning_order_scenarios : Array(TriggerScenario)
    logged = SETUP + [
      "CREATE TABLE log(seq INTEGER PRIMARY KEY, x)",
      "CREATE TRIGGER t_au AFTER UPDATE ON t BEGIN INSERT INTO log (x) VALUES (new.n); END",
      "CREATE TRIGGER t_ai AFTER INSERT ON t BEGIN INSERT INTO log (x) VALUES (new.n); END",
      "CREATE TRIGGER t_ad AFTER DELETE ON t BEGIN INSERT INTO log (x) VALUES (-old.n); END",
    ]
    finish = ["SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY seq"]
    [
      TriggerScenario.new("RETURNING before AFTER triggers, subqueries once or per row", logged + [
        "UPDATE t SET n = n * 2 RETURNING id, n, (SELECT sum(n) FROM t), (SELECT count(*) FROM log), " \
        "(SELECT count(*) FROM log WHERE x <> t.id), (SELECT sum(n) FROM t AS o), (SELECT count(*) FROM log, t)",
        "INSERT INTO t VALUES (4, 0), (5, 0) RETURNING id, (SELECT count(*) FROM log), (SELECT count(*) FROM t)",
        "DELETE FROM t WHERE id > 3 RETURNING id, (SELECT count(*) FROM log), (SELECT count(*) FROM t)",
        "INSERT INTO t VALUES (1, 0), (2, 0) ON CONFLICT (id) DO UPDATE SET n = n + 1 RETURNING id, n, (SELECT count(*) FROM log)",
      ] + finish),
      TriggerScenario.new("RETURNING subqueries nested, compound, through a FROM subquery and a WITH table", logged + [
        "UPDATE t SET n = n + 1 RETURNING id, (SELECT (SELECT sum(n) FROM t) FROM log LIMIT 1), " \
        "(SELECT sum(n) FROM (SELECT * FROM t)), (SELECT sum(n) FROM main.t), EXISTS (SELECT 1 FROM t WHERE n > 7), " \
        "8 IN (SELECT n FROM t), (SELECT sum(n) FROM t UNION ALL SELECT 0 LIMIT 1), " \
        "(SELECT max(v) FROM (SELECT 0 AS v UNION ALL SELECT sum(n) FROM t)), " \
        "(SELECT sum(n) FROM t WHERE 0 UNION ALL SELECT sum(n) FROM t ORDER BY 1 DESC LIMIT 1), " \
        "(WITH c AS (SELECT n FROM t) SELECT sum(n) FROM c)",
      ] + finish),
      TriggerScenario.new("RETURNING leaves out a row a BEFORE trigger skipped or deleted", logged + [
        "CREATE TRIGGER t_bd BEFORE DELETE ON t WHEN old.id = 2 BEGIN SELECT RAISE(IGNORE); END",
        "CREATE TRIGGER t_bu BEFORE UPDATE ON t WHEN old.id = 1 BEGIN DELETE FROM t WHERE id = 1; END",
        "UPDATE t SET n = n + 1 RETURNING id, n",
        "DELETE FROM t RETURNING id, n, (SELECT count(*) FROM t)",
      ] + finish),
      TriggerScenario.new("UPDATE with triggers: an uncorrelated SET subquery is computed once", logged + [
        "UPDATE t SET n = (SELECT sum(n) FROM t)",
        "UPDATE t SET n = (SELECT count(*) FROM log) + id",
        "UPDATE t SET n = (SELECT sum(n) FROM t AS o WHERE o.id <> t.id)",
      ] + finish),
    ]
  end

  def self.list_of_upsert_scenarios : Array(TriggerScenario)
    [
      scenario("upsert SET with an uncorrelated subquery over the same table", [
        "INSERT INTO t VALUES (2, 0) ON CONFLICT (id) DO UPDATE SET n = (SELECT sum(n) FROM t)",
        "INSERT INTO t VALUES (1, 0), (3, 4) ON CONFLICT (id) DO UPDATE SET n = (SELECT sum(n) FROM t) + excluded.n",
      ]),
      scenario("upsert SET with a correlated subquery over the same table", [
        "INSERT INTO t VALUES (1, 0) ON CONFLICT (id) DO UPDATE SET n = (SELECT count(*) FROM t AS o WHERE o.n > t.n)",
        "INSERT INTO t AS a VALUES (3, 0) ON CONFLICT (id) DO UPDATE SET n = (SELECT max(n) FROM t WHERE id <> excluded.id) + a.n",
      ]),
      scenario("upsert WHERE and RETURNING with subqueries over the same table", [
        "INSERT INTO t VALUES (2, 0) ON CONFLICT (id) DO UPDATE SET n = n + 1 WHERE (SELECT count(*) FROM t) > 2 " \
        "RETURNING id, n, (SELECT sum(n) FROM t)",
      ]),
    ]
  end

  # A table whose rows refer to rows of the same table, with *action* for
  # *event* ("UPDATE" or "DELETE").
  def self.self_reference(event : String, action : String) : Array(String)
    [
      "PRAGMA foreign_keys = ON",
      "CREATE TABLE p(id INTEGER PRIMARY KEY, parent INTEGER DEFAULT 3 REFERENCES p(id) ON #{event} #{action}, n INTEGER)",
      "INSERT INTO p VALUES (1, NULL, 0), (2, 1, 0), (3, NULL, 0), (4, 2, 0)",
    ]
  end

  def self.list_of_foreign_key_scenarios : Array(TriggerScenario)
    list = [] of TriggerScenario
    {"CASCADE", "SET NULL", "SET DEFAULT"}.each do |action|
      list << TriggerScenario.new("UPDATE of a self-reference with ON UPDATE #{action}", self_reference("UPDATE", action) + [
        "UPDATE p SET id = id + 10, n = coalesce(parent, -1) WHERE id IN (1, 2)",
        "SELECT changes(), total_changes()",
        "SELECT * FROM p ORDER BY id",
        "UPDATE p SET n = parent * 100 + n",
        "SELECT * FROM p ORDER BY id",
      ])
    end
    {"CASCADE", "SET DEFAULT"}.each do |action|
      list << TriggerScenario.new("UPDATE OR REPLACE of two rows of a self-reference with ON DELETE #{action}", self_reference("DELETE", action) + [
        "UPDATE OR REPLACE p SET id = CASE id WHEN 2 THEN 1 ELSE id END, n = coalesce(parent, -1) WHERE id IN (2, 4)",
        "SELECT changes(), total_changes()",
        "SELECT * FROM p ORDER BY id",
        "DELETE FROM p WHERE id IN (1, 3) RETURNING id, parent, n",
        "SELECT * FROM p ORDER BY id",
      ])
    end
    {"CASCADE", "SET NULL", "SET DEFAULT", "NO ACTION"}.each do |action|
      list << TriggerScenario.new("UPDATE OR REPLACE of one row of a self-reference with ON DELETE #{action}", self_reference("DELETE", action) + [
        "UPDATE OR REPLACE p SET id = 1, n = coalesce(parent, -1) WHERE id = 2",
        "SELECT changes(), total_changes()",
        "SELECT * FROM p ORDER BY id",
        "UPDATE OR REPLACE p SET id = 1 WHERE id = 3",
        "SELECT changes(), total_changes()",
        "SELECT * FROM p ORDER BY id",
      ])
      list << TriggerScenario.new("DELETE of rows that refer to themselves with ON DELETE #{action}", [
        "PRAGMA foreign_keys = ON",
        "CREATE TABLE q(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES q(id) ON DELETE #{action})",
        "INSERT INTO q VALUES (1, 1), (5, 5), (6, 5), (7, 6)",
        "DELETE FROM q WHERE id = 1",
        "SELECT changes(), total_changes()",
        "DELETE FROM q WHERE id IN (5, 6)",
        "SELECT changes(), total_changes()",
        "SELECT * FROM q ORDER BY id",
      ])
    end
    list << TriggerScenario.new("UPDATE of a parent whose child table has ON UPDATE CASCADE", [
      "PRAGMA foreign_keys = ON",
      "CREATE TABLE parent_rows(id INTEGER PRIMARY KEY, n INTEGER)",
      "CREATE TABLE child_rows(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent_rows(id) ON UPDATE CASCADE)",
      "INSERT INTO parent_rows VALUES (1, 0), (2, 0)",
      "INSERT INTO child_rows VALUES (1, 1), (2, 2)",
      "UPDATE parent_rows SET id = id + 10, n = (SELECT count(*) FROM child_rows WHERE parent_id > parent_rows.id)",
      "SELECT * FROM parent_rows ORDER BY id",
      "SELECT * FROM child_rows ORDER BY id",
    ])
    list
  end
end

describe "Grant::SQLiteEngine::Query writes that read their own table against C SQLite 3.51.0" do
  linked = SQLiteSQLOracle.version.split(' ').first
  if linked == "3.51.0"
    list = SameTableReadsDifferentialFixture.list_of_returning_scenarios +
           SameTableReadsDifferentialFixture.list_of_returning_order_scenarios +
           SameTableReadsDifferentialFixture.list_of_upsert_scenarios +
           SameTableReadsDifferentialFixture.list_of_foreign_key_scenarios
    list.each do |scenario|
      it "matches C: #{scenario.name}" do
        report = TriggerReport.new
        work = File.join(Dir.tempdir, "grant-same-table-reads-#{Random::Secure.hex(6)}")
        begin
          TriggerDifferential.new(report, work).run(scenario)
        ensure
          FileUtils.rm_rf(work)
        end
        report.list_of_differences.should eq([] of String)
        report.list_of_unexpressed.should eq([] of String)
      end
    end

    # isSetNullAction (fkey.c) asks whether the newest trigger program the
    # top-level statement has coded is this foreign key's SET NULL action.
    # After a REPLACE has coded that action for a self-reference, the
    # answer is yes for the statement's own rows too, so C skips the check
    # of each later row's new parent and lets a dangling child through.
    pending "matches C's skipped parent check after a REPLACE coded a self-reference's ON DELETE SET NULL " \
            "(UPDATE OR REPLACE p SET id = CASE id WHEN 2 THEN 1 ELSE id END WHERE id IN (2, 4))"
  else
    pending "matches C on writes that read their own table (the linked libsqlite3 is #{linked})"
  end
end
