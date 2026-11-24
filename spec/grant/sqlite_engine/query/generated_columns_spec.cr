require "spec"
require "../../../support/sqlite_engine/generated_column_differential"

private def assert_same(list_of_statements : Array(String), list_of_queries : Array(String)) : Nil
  list_of_differences = GeneratedColumnDifferential.differences(list_of_statements, list_of_queries)
  fail(list_of_differences.join("\n")) unless list_of_differences.empty?
end

describe "Grant::SQLiteEngine generated columns" do
  describe "VIRTUAL columns" do
    it "computes a virtual column when it is read, with the column's affinity, as C does" do
      assert_same([
        "CREATE TABLE t(a INTEGER, b TEXT, double INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL, short AS (a * 2), " \
        "label TEXT AS (a), ratio REAL AS (a), half INTEGER AS (a / 2.0), words AS (b || '!') VIRTUAL, " \
        "kept INTEGER AS (a + 1) STORED, after_kept AS (kept * 10))",
        "INSERT INTO t(a, b) VALUES (3, 'x'), (NULL, NULL), (4, '7'), ('5', 9), (2.0, 'abc')",
      ], [
        "SELECT * FROM t ORDER BY rowid",
        "SELECT typeof(double), typeof(short), typeof(label), typeof(ratio), typeof(half), typeof(words), typeof(after_kept) FROM t ORDER BY rowid",
        "SELECT a FROM t WHERE double > 5 ORDER BY double DESC",
        "SELECT a FROM t WHERE label = 3",
        "SELECT a FROM t WHERE ratio = '4'",
        "SELECT count(*), sum(double), group_concat(words) FROM t",
        "SELECT rowid, double FROM t WHERE double IS NULL",
        "SELECT cid, name, type, hidden FROM pragma_table_xinfo('t')",
        "PRAGMA table_info(t)",
      ])
    end

    it "reads a virtual column that reads generated columns declared before and after it" do
      assert_same([
        "CREATE TABLE t(first AS (second + 1), a INTEGER, second AS (third * 2), third INTEGER AS (a + 100) STORED, last AS (first || '/' || second))",
        "INSERT INTO t(a) VALUES (1), (2), (NULL)",
        "UPDATE t SET a = a + 10 WHERE first > 205",
      ], ["SELECT * FROM t ORDER BY a", "SELECT a FROM t WHERE last = '225/224'"])
    end

    it "uses and maintains indexes on virtual columns" do
      assert_same([
        "CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, total AS (a * 10), tag TEXT AS (upper(b)) VIRTUAL)",
        "CREATE INDEX t_total ON t(total)",
        "CREATE UNIQUE INDEX t_tag ON t(tag)",
        "CREATE INDEX t_both ON t(tag, total DESC) WHERE total > 20",
        "INSERT INTO t(a, b) VALUES (1, 'x'), (2, 'y'), (3, 'z'), (4, 'w')",
        "INSERT INTO t(a, b) VALUES (9, 'X')",
        "INSERT OR REPLACE INTO t(a, b) VALUES (9, 'X')",
        "UPDATE t SET a = a + 1 WHERE total >= 30",
        "UPDATE t SET b = 'y' WHERE id = 1",
        "DELETE FROM t WHERE tag = 'W'",
        "CREATE INDEX t_late ON t(total, tag)",
      ], [
        "SELECT * FROM t",
        "SELECT id FROM t WHERE total = 40",
        "SELECT id, total FROM t WHERE total > 15 ORDER BY total DESC",
        "SELECT total FROM t",
        "SELECT tag FROM t",
        "SELECT tag, total FROM t WHERE total > 20",
        "SELECT id FROM t WHERE tag IN ('X', 'Y') ORDER BY tag",
        "SELECT count(*) FROM t WHERE tag > 'A'",
        "PRAGMA integrity_check",
        "PRAGMA index_xinfo(t_both)",
      ])
    end

    it "refuses to write a generated column, with C's messages" do
      assert_same([
        "CREATE TABLE t(a INTEGER UNIQUE, v AS (a + 1), s AS (a + 2) STORED)",
        "INSERT INTO t(a) VALUES (1) ON CONFLICT DO UPDATE SET v = 3",
        "INSERT INTO t(a) VALUES (1) ON CONFLICT DO UPDATE SET s = 3",
        "INSERT INTO t(v) VALUES (1)",
        "INSERT INTO t(a, s) VALUES (1, 2)",
        "INSERT INTO t VALUES (1, 2)",
        "INSERT INTO t VALUES (1)",
        "UPDATE t SET v = 1",
        "UPDATE t SET s = 1",
        "UPDATE t SET (a, v) = (1, 2)",
      ], ["SELECT * FROM t"])
    end

    it "checks NOT NULL, CHECK, UNIQUE and STRICT types on virtual columns" do
      assert_same([
        "CREATE TABLE t(a, b, v INTEGER NOT NULL AS (a + b), w AS (a * 2) UNIQUE, CHECK (v < 100), CHECK (w IS NOT 8))",
        "INSERT INTO t(a, b) VALUES (1, 2)",
        "INSERT INTO t(a, b) VALUES (1, NULL)",
        "INSERT INTO t(a, b) VALUES (1, 5)",
        "INSERT INTO t(a, b) VALUES (60, 50)",
        "INSERT INTO t(a, b) VALUES (4, 1)",
        "INSERT OR IGNORE INTO t(a, b) VALUES (2, NULL), (3, 3)",
        "UPDATE t SET b = NULL",
        "UPDATE t SET a = 4",
        "CREATE TABLE s(a ANY, v INTEGER AS (a) VIRTUAL, w TEXT AS (a) STORED) STRICT",
        "INSERT INTO s(a) VALUES (1)",
        "INSERT INTO s(a) VALUES ('2')",
        "INSERT INTO s(a) VALUES ('x')",
        "INSERT INTO s(a) VALUES (2.5)",
        "CREATE TABLE s2(a ANY, v INTEGER AS (a) VIRTUAL) STRICT",
        "INSERT INTO s2(a) VALUES ('x')",
        "INSERT INTO s2(a) VALUES (x'00')",
      ], ["SELECT * FROM t ORDER BY a", "SELECT a, typeof(v), typeof(w) FROM s", "SELECT a FROM s2", "SELECT v FROM s2", "SELECT count(*) FROM s2"])
    end

    it "reads NULL for a virtual column of the NULL row of a LEFT JOIN" do
      assert_same([
        "CREATE TABLE l(x)", "CREATE TABLE r(y, filled AS (coalesce(y, 'none')), kept AS (coalesce(y, 'none')) STORED)",
        "INSERT INTO l VALUES (1), (2)", "INSERT INTO r(y) VALUES (1), (NULL)",
      ], [
        "SELECT x, y, filled, kept FROM l LEFT JOIN r ON y = x ORDER BY x",
        "SELECT x FROM l LEFT JOIN r ON y = x WHERE filled IS NULL",
        "SELECT x, filled FROM l LEFT JOIN r ON filled = 'none' ORDER BY x",
      ])
    end

    it "handles virtual columns in WITHOUT ROWID tables" do
      assert_same([
        "CREATE TABLE t(code TEXT PRIMARY KEY, shown AS (lower(code)), n INTEGER, twice AS (n * 2) VIRTUAL, kept AS (n + 1) STORED) WITHOUT ROWID",
        "CREATE INDEX t_twice ON t(twice)",
        "INSERT INTO t(code, n) VALUES ('B', 2), ('A', 1), ('C', 3)",
        "UPDATE t SET n = n * 10 WHERE twice >= 4",
        "DELETE FROM t WHERE shown = 'c'",
        "INSERT OR REPLACE INTO t(code, n) VALUES ('A', 7)",
      ], ["SELECT * FROM t", "SELECT code FROM t WHERE twice = 40", "SELECT twice FROM t ORDER BY twice", "PRAGMA integrity_check"])
    end

    it "evaluates RETURNING, upsert and triggerless foreign keys over virtual columns" do
      assert_same([
        "PRAGMA foreign_keys = ON",
        "CREATE TABLE parent(id INTEGER PRIMARY KEY, code AS (id * 100) UNIQUE)",
        "CREATE TABLE child(n INTEGER, parent_code AS (n * 100) REFERENCES parent(code) ON DELETE CASCADE)",
        "INSERT INTO parent(id) VALUES (1), (2)",
        "INSERT INTO child(n) VALUES (1), (2), (2)",
        "INSERT INTO child(n) VALUES (3)",
        "INSERT INTO child(n) VALUES (1) RETURNING n, parent_code, typeof(parent_code)",
        "UPDATE child SET n = 2 WHERE parent_code = 100 RETURNING *",
        "DELETE FROM parent WHERE code = 200",
        "CREATE TABLE u(k INTEGER PRIMARY KEY, n, v AS (n + 1))",
        "INSERT INTO u VALUES (1, 1)",
        "INSERT INTO u VALUES (1, 5) ON CONFLICT(k) DO UPDATE SET n = excluded.v + v RETURNING v",
      ], ["SELECT * FROM parent", "SELECT * FROM child", "SELECT * FROM u"])
    end
  end

  describe "CREATE TABLE" do
    it "reports C's errors for generated column definitions" do
      assert_same([
        "CREATE TABLE loop1(a, b AS (c), c AS (b))",
        "CREATE TABLE loop2(a, b AS (b + 1))",
        "CREATE TABLE loop3(a, b AS (c) STORED, c AS (b) STORED)",
        "CREATE TABLE loop4(a, b AS (c) STORED, c AS (d), d AS (b + a))",
        "CREATE TABLE only_generated(b AS (1))",
        "CREATE TABLE missing(a, b AS (nope + 1))",
        "CREATE TABLE keyed(a, b AS (a) PRIMARY KEY)",
        "CREATE TABLE defaulted(a, b DEFAULT 1 AS (a))",
        "CREATE TABLE odd(a, b AS (a) SOMETIMES)",
        "CREATE TABLE sub(a, b AS ((SELECT 1)))",
        "CREATE TABLE agg(a, b AS (sum(a)))",
        "CREATE TABLE volatile(a, b AS (random()))",
        "CREATE TABLE rowid_reader(a, b AS (rowid + 1))",
        "CREATE TABLE fine(a, b AS (a) VIRTUAL, c AS (b) STORED)",
        "INSERT INTO fine(a) VALUES (5)",
      ], ["SELECT name FROM sqlite_schema ORDER BY name", "SELECT * FROM fine"])
    end
  end

  describe "ALTER TABLE" do
    it "adds a VIRTUAL column to a table with rows and refuses a STORED one" do
      assert_same([
        "CREATE TABLE t(a INTEGER, b TEXT)",
        "INSERT INTO t VALUES (1, 'x'), (2, 'y')",
        "ALTER TABLE t ADD COLUMN v AS (a * 3)",
        "ALTER TABLE t ADD COLUMN s AS (a * 4) STORED",
        "ALTER TABLE t ADD COLUMN w TEXT GENERATED ALWAYS AS (b || v) VIRTUAL NOT NULL",
        "ALTER TABLE t ADD COLUMN bad AS (nope)",
        "ALTER TABLE t ADD COLUMN plain INTEGER DEFAULT 7",
        "CREATE INDEX t_v ON t(v)",
        "INSERT INTO t(a, b) VALUES (3, 'z')",
        "CREATE TABLE empty(a)",
        "ALTER TABLE empty ADD COLUMN s AS (a + 1) STORED",
        "INSERT INTO empty(a) VALUES (1)",
        "ALTER TABLE t RENAME COLUMN a TO renamed",
        "ALTER TABLE t DROP COLUMN b",
        "ALTER TABLE t DROP COLUMN w",
        "ALTER TABLE t DROP COLUMN b",
      ], [
        "SELECT * FROM t ORDER BY 1", "SELECT renamed FROM t WHERE v = 6", "SELECT * FROM empty",
        "SELECT sql FROM sqlite_schema ORDER BY name", "PRAGMA integrity_check",
        "SELECT name, hidden FROM pragma_table_xinfo('t')",
      ])
    end
  end

  describe "seeded random differential" do
    it "matches C over random tables mixing STORED and VIRTUAL columns" do
      seed = (ENV["GRANT_GENERATED_COLUMNS_SEED"]? || "20261124").to_u64
      rounds = (ENV["GRANT_GENERATED_COLUMNS_ROUNDS"]? || "150").to_i
      random = Random.new(seed)
      statement_count = 0
      list_of_differences = [] of String
      rounds.times do |round|
        statements, queries = GeneratedColumnDifferential.random_case(random)
        statement_count += statements.size + queries.size
        found = GeneratedColumnDifferential.differences(statements, queries)
        next if found.empty?
        list_of_differences << "round #{round}: #{statements.join("; ")}\n    #{found.first(3).join("\n    ")}"
        break if list_of_differences.size >= 5
      end
      if summary_path = ENV["GRANT_GENERATED_COLUMNS_SUMMARY"]?
        File.write(summary_path, "generated column differential: seed #{seed}, #{rounds} tables, #{statement_count} statements, " \
                                 "#{list_of_differences.size} differing tables\n")
      end
      fail(list_of_differences.join("\n")) unless list_of_differences.empty?
    end
  end
end
