require "spec"
require "../../../support/sqlite_engine/query_oracle"

# Fixed SELECT statements over a database C SQLite builds, each run on both
# engines and compared row for row (typed, reals by bits).
module SelectSpecFixture
  SETUP = <<-SQL
    CREATE TABLE users (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL, name TEXT COLLATE NOCASE,
      age INTEGER, score REAL, joined DATETIME, flag BOOL DEFAULT 0);
    CREATE UNIQUE INDEX index_users_on_email ON users (email);
    CREATE INDEX index_users_on_age ON users (age);
    CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      title VARCHAR(100), body TEXT, rank NUMERIC, published BOOLEAN, created_at TIMESTAMP);
    CREATE INDEX index_posts_on_user_id ON posts (user_id);
    CREATE TABLE tags (code TEXT PRIMARY KEY, label TEXT) WITHOUT ROWID;
    CREATE TABLE big_keys (id BIGINT PRIMARY KEY, note TEXT);
    CREATE TABLE nodes (id INTEGER PRIMARY KEY, parent_id INTEGER, label TEXT, weight INTEGER);
    CREATE TABLE ranked (code TEXT, level INTEGER);
    CREATE INDEX index_ranked_on_level ON ranked (level DESC);
    INSERT INTO ranked VALUES ('x', 1), ('y', NULL), ('z', 3), ('w', 9223372036854775807), ('v', 9223372036854775808.0);
    CREATE VIEW adult_users AS SELECT id, name, age FROM users WHERE age >= 18;
    INSERT INTO users VALUES (1, 'ada@example.com', 'Ada', 36, 9.5, '2026-11-01 10:00:00.000000', 1);
    INSERT INTO users VALUES (2, 'bob@example.com', 'bob', 17, NULL, '2026-11-02 11:30:00.123456', 0);
    INSERT INTO users VALUES (3, 'cy@example.com', 'CY', NULL, 7.25, NULL, 1);
    INSERT INTO users VALUES (4, 'di@example.com', NULL, 52, 3, '2026-10-30 09:15:00.000000', 0);
    INSERT INTO users VALUES (5, 'ed@example.com', 'ed', 36, -1.5, '2026-11-03 00:00:00.000000', 1);
    INSERT INTO posts (user_id, title, body, rank, published, created_at) VALUES
      (1, 'First', 'hello world', 10, 1, '2026-11-01'), (1, 'Second', NULL, '2.5', 0, '2026-11-02'),
      (2, 'Third', 'abc', 'x', 1, NULL), (5, 'Fourth', 'Hello', 7, 1, '2026-11-04'), (NULL, 'Orphan', '', 0, 0, NULL),
      (1, 'Fifth', '50%', 3, NULL, '2026-11-05');
    INSERT INTO tags VALUES ('b', 'Bee'), ('a', 'Ay'), ('c', NULL);
    INSERT INTO big_keys VALUES (10, 'ten'), (20, 'twenty');
    INSERT INTO nodes VALUES (1, NULL, 'root', 1), (2, 1, 'a', 2), (3, 1, 'b', 3), (4, 2, 'a1', 4), (5, 4, 'a1x', 5);
    CREATE TABLE pairs (a TEXT, b TEXT, PRIMARY KEY (a, b, a)) WITHOUT ROWID;
    INSERT INTO pairs VALUES ('x', 'y'), ('a', 'b'), ('a', 'c');
    CREATE TABLE named (a, b, c, PRIMARY KEY(a) UNIQUE (b) CONSTRAINT one CHECK(c < 10) CONSTRAINT two);
    INSERT INTO named VALUES (1, 2, 3);
    SQL

  QUERIES = [
    {"SELECT * FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id, email FROM users WHERE id = ?", [3_i64] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE id = ?", ["3"] of Grant::SQLiteEngine::Value},
    {"SELECT id, name FROM users ORDER BY name", [] of Grant::SQLiteEngine::Value},
    {"SELECT id, name FROM users ORDER BY name DESC NULLS LAST, id", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE name = 'ADA'", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE name = 'ADA' COLLATE BINARY", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age = '36'", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age > ? ORDER BY id LIMIT 2 OFFSET 1", [10_i64] of Grant::SQLiteEngine::Value},
    {"SELECT count(*), sum(age), avg(age), min(score), max(score), total(score), group_concat(name) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT age, count(*) FROM users GROUP BY age ORDER BY age", [] of Grant::SQLiteEngine::Value},
    {"SELECT age, count(*) AS n FROM users GROUP BY 1 HAVING n > 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT u.id, p.title FROM users u JOIN posts p ON p.user_id = u.id ORDER BY p.id", [] of Grant::SQLiteEngine::Value},
    {"SELECT u.id, p.title FROM users u LEFT JOIN posts p ON p.user_id = u.id ORDER BY u.id, p.id", [] of Grant::SQLiteEngine::Value},
    {"SELECT users.id FROM users LEFT OUTER JOIN posts ON posts.user_id = users.id WHERE posts.id IS NULL", [] of Grant::SQLiteEngine::Value},
    {"SELECT DISTINCT users.name FROM users INNER JOIN posts ON posts.user_id = users.id", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE id IN (?, ?, 9)", [1_i64, 4_i64] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE id IN (SELECT user_id FROM posts WHERE published = 1)", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE id NOT IN (SELECT user_id FROM posts)", [] of Grant::SQLiteEngine::Value},
    {"SELECT id, (SELECT count(*) FROM posts WHERE posts.user_id = users.id) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE EXISTS (SELECT 1 FROM posts WHERE posts.user_id = users.id) ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT EXISTS(SELECT 1 FROM users WHERE \"email\" = ?)", ["ada@example.com"] of Grant::SQLiteEngine::Value},
    {"SELECT title FROM posts WHERE body LIKE 'hel%'", [] of Grant::SQLiteEngine::Value},
    {"SELECT title FROM posts WHERE body LIKE '%\\%%' ESCAPE '\\'", [] of Grant::SQLiteEngine::Value},
    {"SELECT title FROM posts WHERE body GLOB 'H*'", [] of Grant::SQLiteEngine::Value},
    {"SELECT rank, typeof(rank) FROM posts", [] of Grant::SQLiteEngine::Value},
    {"SELECT CAST(rank AS INTEGER), CAST(rank AS REAL), CAST(rank AS TEXT), CAST(score AS NUMERIC) FROM posts, users WHERE users.id = 3", [] of Grant::SQLiteEngine::Value},
    {"SELECT 1 + 1, 7 / 2, 7.0 / 2, 7 % 3, -7 % 3, 1 / 0, 9223372036854775807 + 1, 'abc' + 1, '3x' * 2, 2 || 3", [] of Grant::SQLiteEngine::Value},
    {"SELECT coalesce(name, 'none'), ifnull(age, -1), nullif(age, 36), lower(email), upper(name), length(name) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT substr(email, 2, 3), substr(email, -3), replace(email, '@', ' at '), instr(email, 'e'), trim('  x  '), abs(score), round(score), round(score, 1) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT hex(email), quote(name), quote(score), quote(NULL), typeof(score) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT CASE WHEN age > 30 THEN 'old' WHEN age IS NULL THEN 'unknown' ELSE 'young' END, CASE age WHEN 36 THEN 'x' END FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age BETWEEN 17 AND 36 ORDER BY id DESC", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE (id, age) IN (VALUES (1, 36), (2, 17))", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE (id, age) NOT IN (VALUES (?, ?), (?, ?))", [1_i64, 36_i64, 5_i64, 36_i64] of Grant::SQLiteEngine::Value},
    {"SELECT name FROM users UNION SELECT label FROM tags ORDER BY 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT age FROM users UNION ALL SELECT weight FROM nodes", [] of Grant::SQLiteEngine::Value},
    {"SELECT age FROM users INTERSECT SELECT 36", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users EXCEPT SELECT user_id FROM posts", [] of Grant::SQLiteEngine::Value},
    {"WITH adults AS (SELECT id, age FROM users WHERE age >= 18) SELECT count(*) FROM adults", [] of Grant::SQLiteEngine::Value},
    {"WITH RECURSIVE tree(id, depth) AS (SELECT id, 0 FROM nodes WHERE parent_id IS NULL UNION ALL SELECT nodes.id, tree.depth + 1 FROM nodes JOIN tree ON nodes.parent_id = tree.id) SELECT * FROM tree ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"WITH RECURSIVE counter(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM counter LIMIT 10) SELECT sum(n) FROM counter", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM adult_users ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM tags ORDER BY code", [] of Grant::SQLiteEngine::Value},
    {"SELECT rowid, id FROM big_keys", [] of Grant::SQLiteEngine::Value},
    {"SELECT rowid, oid, _rowid_ FROM users WHERE rowid > 3", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(DISTINCT age), count(age), count(*) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT x FROM (SELECT id * 2 AS x FROM users) WHERE x > 4", [] of Grant::SQLiteEngine::Value},
    {"SELECT COUNT(*) FROM (SELECT 1 FROM users ORDER BY id ASC LIMIT 2) AS grant_limited_rows", [] of Grant::SQLiteEngine::Value},
    {"SELECT name, type FROM sqlite_master ORDER BY name", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM pragma_table_xinfo('users')", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM pragma_index_list('users')", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM pragma_index_xinfo('index_users_on_email')", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM pragma_foreign_key_list('posts')", [] of Grant::SQLiteEngine::Value},
    {"SELECT m.name, fk.\"table\" FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) fk WHERE m.type = 'table'", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE email = ?", ["bob@example.com"] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age IS NULL OR score IS NOT NULL", [] of Grant::SQLiteEngine::Value},
    {"SELECT TRUE, FALSE, NULL IS NULL, 1 IS NOT 2, NOT 0", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users ORDER BY id LIMIT ?", ["2"] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users ORDER BY id LIMIT ?", ["x"] of Grant::SQLiteEngine::Value},
    {"SELECT nope FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM nope", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users, posts", [] of Grant::SQLiteEngine::Value},
    {"SELECT \"missing\" FROM users WHERE id = 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT max(age, 40), min(score, 5) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT name, max(age) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age > 100 AND abs(-9223372036854775807 - 1) > 0", [] of Grant::SQLiteEngine::Value},
    {"SELECT age > 100 AND abs(-9223372036854775807 - 1) > 0 FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT DISTINCT name FROM users UNION SELECT 'ADA' ORDER BY 1 COLLATE NOCASE", [] of Grant::SQLiteEngine::Value},
    {"SELECT score, score FROM users UNION SELECT 1, 2 ORDER BY 1 COLLATE BINARY", [] of Grant::SQLiteEngine::Value},
    {"SELECT x FROM (SELECT CAST(age AS REAL) AS x FROM users UNION SELECT '7')", [] of Grant::SQLiteEngine::Value},
    {"SELECT substr(x'', 1, 2), substr(NULL, 1), substr('abc', 0), substr('abc', -5, 3)", [] of Grant::SQLiteEngine::Value},
    {"SELECT u.id, p.title FROM users u JOIN posts p USING (id) ORDER BY 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT 2 NOT IN (SELECT level FROM ranked), 2 NOT IN (SELECT level FROM ranked WHERE 1), 2 NOT IN (SELECT parent_id FROM nodes)", [] of Grant::SQLiteEngine::Value},
    {"SELECT 9223372036854775807 IN (SELECT CAST(level AS REAL) FROM ranked), 9223372036854775807 IN (SELECT CAST(level AS REAL) FROM ranked WHERE 1), 9223372036854775807 = (SELECT CAST(level AS REAL) FROM ranked WHERE code = ?)", ["v"] of Grant::SQLiteEngine::Value},
    {"SELECT abs(-0.0), abs(-(0.0)), abs(-1.5)", [] of Grant::SQLiteEngine::Value},
    {"SELECT NULL, 32 UNION SELECT NULL, -4.25 UNION SELECT 1, 0 ORDER BY 1 LIMIT 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT x'af', NULL UNION SELECT x'af', x'' UNION ALL SELECT x'af', 1 ORDER BY 1 DESC LIMIT 5 OFFSET 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT seq, name, file FROM pragma_database_list", [] of Grant::SQLiteEngine::Value},
    {"WITH t(id) AS (VALUES(2) UNION ALL SELECT id + 1 FROM t WHERE id < 5) SELECT id FROM t", [] of Grant::SQLiteEngine::Value},
    {"WITH t(id) AS (VALUES(2) UNION ALL SELECT id FROM nodes WHERE parent_id IN (SELECT id FROM t)) SELECT id FROM t", [] of Grant::SQLiteEngine::Value},
    {"WITH t(id) AS (VALUES(2) UNION ALL SELECT nodes.id FROM nodes, t WHERE parent_id = t.id AND parent_id IN (SELECT id FROM t)) SELECT id FROM t", [] of Grant::SQLiteEngine::Value},
    {"WITH t(id) AS (SELECT id FROM nodes WHERE 2 IN (SELECT id FROM t) UNION ALL SELECT nodes.id FROM nodes, t WHERE parent_id = t.id) SELECT id FROM t", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM users NATURAL JOIN posts USING (id)", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE likelihood(age > 3, 1.5)", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE likelihood(age > 3, 0.25) ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT 'abc' UNION ALL SELECT 'DEF' ORDER BY 1 COLLATE nocase COLLATE binary", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE (id, age) = (SELECT 1, 36) ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE (name, id) = (SELECT 'ADA', 1)", [] of Grant::SQLiteEngine::Value},
    {"SELECT (SELECT 3, 4 UNION SELECT 5, 6 ORDER BY 1) IN (SELECT 3, 4), (SELECT 1, 2) < (1, 3), (1, 2) BETWEEN (0, 9) AND (1, 2)", [] of Grant::SQLiteEngine::Value},
    {"SELECT 1 WHERE (2, (2, 0)) IS (2, (2, 0))", [] of Grant::SQLiteEngine::Value},
    {"SELECT (SELECT 1, 2) + 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT k FROM users WHERE nothing_here", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE no_a = 1 AND no_b = 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT abs(no_col, 2), outer_fn(no_col) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE (SELECT no_b) AND no_a = 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT outer_fn(inner_fn(1))", [] of Grant::SQLiteEngine::Value},
    {"WITH t(a) AS (VALUES(1, 2)) SELECT * FROM t", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users ORDER BY 1, 7", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(*) FROM users GROUP BY max(age)", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(*) FROM posts", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(*) FROM tags", [] of Grant::SQLiteEngine::Value},
    {"SELECT x_count(*) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT 9 IS (2 NOT IN ()), 9 IS (2 IN ()), 0 IS TRUE, NULL IS NOT FALSE, 5 IS FALSE, NULL IS TRUE, 'x' IS NOT TRUE, 2 IN (), 2 NOT IN ()", [] of Grant::SQLiteEngine::Value},
    {"SELECT quote(1e999), quote(-1e999), quote(0.1)", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age IS TRUE ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT age, count(*) AS c FROM users WHERE c > 1 GROUP BY age", [] of Grant::SQLiteEngine::Value},
    {"SELECT age FROM users WHERE count(*) > 1 GROUP BY age", [] of Grant::SQLiteEngine::Value},
    {"SELECT max(age) AS m FROM users GROUP BY 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users HAVING count(*) > 0", [] of Grant::SQLiteEngine::Value},
    {"SELECT min(age) FROM users LIMIT 0, 100", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users ORDER BY id LIMIT 1, 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT 0.5 IS TRUE COLLATE NOCASE, 1 IN (2 IS TRUE), 0 IS NOT likely(FALSE)", [] of Grant::SQLiteEngine::Value},
    {"WITH t(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM t) SELECT x FROM t LIMIT 2", [] of Grant::SQLiteEngine::Value},
    {"WITH t(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM t LIMIT 1, 3) SELECT x FROM t", [] of Grant::SQLiteEngine::Value},
    {"SELECT name FROM users UNION SELECT title FROM posts ORDER BY users.name", [] of Grant::SQLiteEngine::Value},
    {"SELECT quote(CAST(x'cf27e8' AS TEXT))", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(*) FROM users LEFT JOIN posts ON no_c = 1 WHERE no_d IS NULL", [] of Grant::SQLiteEngine::Value},
    {"SELECT no_r FROM users LEFT JOIN posts ON no_c = 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(*) FROM users JOIN posts ON users.id = nodes.id JOIN nodes", [] of Grant::SQLiteEngine::Value},
    {"SELECT count(*) FROM users LEFT JOIN posts ON users.id = nodes.id JOIN nodes", [] of Grant::SQLiteEngine::Value},
    {"SELECT users.id, posts.id FROM users LEFT JOIN posts ON posts.user_id = users.id AND users.age > 20 ORDER BY 1, 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE random() > 0 OR 1 ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT level, count(*) FROM ranked GROUP BY level", [] of Grant::SQLiteEngine::Value},
    {"SELECT u.id, p.id FROM users u LEFT JOIN posts p ON p.user_id = u.id WHERE p.rank > 2 ORDER BY 1, 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT u.id, p.id FROM users u LEFT JOIN posts p ON p.user_id = u.id WHERE p.rank > 2 OR u.id = 3 ORDER BY 1, 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT code FROM tags EXCEPT SELECT abs(-9223372036854775807 - 1) FROM tags WHERE 0", [] of Grant::SQLiteEngine::Value},
    {"SELECT 1 WHERE 0 INTERSECT SELECT abs(-9223372036854775807 - 1)", [] of Grant::SQLiteEngine::Value},
    {"SELECT DISTINCT level FROM ranked", [] of Grant::SQLiteEngine::Value},
    {"SELECT 0.1 + 0.2, 1e300 * 1e300, -0.0, 1.5e-7, 123456789012345678, CAST(0.1 AS TEXT), 100.0", [] of Grant::SQLiteEngine::Value},
    # Bare columns take the row of the last min() or max() that took a new value.
    {"SELECT name, max(age) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT flag, name, min(age), max(score) FROM users GROUP BY flag ORDER BY flag", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE id IN ((SELECT user_id FROM posts)) ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT id, likely(age) = '36' FROM users ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT (SELECT max(users.age) FROM posts LIMIT 1) FROM users", [] of Grant::SQLiteEngine::Value},
    # C's resolve walk: a function's own error first, the walk stops at the
    # next node once an error is recorded, IS NULL and function argument
    # lists absorb a stopped walk, and the last recorded error is reported.
    {"SELECT * FROM users WHERE nofunc(1) AND no_col = 1", [] of Grant::SQLiteEngine::Value},
    {"SELECT nofunc(1) + (no_col IS NULL) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT (no_col IS NULL) + nofunc(1) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT nofunc('x', no_col) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT outer_fn(inner_fn(no_col))", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM users WHERE no_col REGEXP 'x'", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE no_col LIKE no_pattern", [] of Grant::SQLiteEngine::Value},
    {"SELECT SUM(*) FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE no_x IN (SELECT no_y FROM posts)", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM nosuch1 UNION ALL SELECT * FROM nosuch2", [] of Grant::SQLiteEngine::Value},
    {"SELECT no_x FROM users UNION SELECT no_y FROM posts", [] of Grant::SQLiteEngine::Value},
    {"SELECT 1, 2 UNION SELECT 3 UNION SELECT 4, 5", [] of Grant::SQLiteEngine::Value},
    {"WITH i(x) AS (SELECT 1, 2 UNION ALL SELECT 1) SELECT * FROM i", [] of Grant::SQLiteEngine::Value},
    {"WITH RECURSIVE i(x) AS (VALUES(1) UNION SELECT count(*) FROM i) SELECT * FROM i", [] of Grant::SQLiteEngine::Value},
    {"WITH s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 3 UNION ALL SELECT 4) SELECT * FROM s", [] of Grant::SQLiteEngine::Value},
    {"SELECT 1 INTERSECT VALUES(count())", [] of Grant::SQLiteEngine::Value},
    {"SELECT 1 WHERE (1, 2) IN ((1, 2, 3), (1, 2))", [] of Grant::SQLiteEngine::Value},
    {"SELECT id, CASE (id, age) WHEN (1, 36) THEN 'a' WHEN (5, 36) THEN 'e' ELSE '-' END FROM users ORDER BY id", [] of Grant::SQLiteEngine::Value},
    # Table-valued function and INDEXED BY errors of the expand phase.
    {"SELECT * FROM adult_users(1)", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM main.nosuch_fn(1)", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM nosuch_fn(no_col)", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM adult_users INDEXED BY index_users_on_age", [] of Grant::SQLiteEngine::Value},
    {"SELECT name, ncol, wr, strict FROM pragma_table_list('pairs')", [] of Grant::SQLiteEngine::Value},
    {"SELECT hex(unhex('41 42', ' ')), unhex('4'), unhex('zz'), unhex(NULL), hex(unhex('6162'))", [] of Grant::SQLiteEngine::Value},
    {"SELECT load_extension('nothing')", [] of Grant::SQLiteEngine::Value},
    # Plans: a LIMIT that overflows, a covering index read in order, WHERE
    # terms tested as the scan decodes their columns.
    {"SELECT id FROM users ORDER BY id LIMIT 9223372036854775807 OFFSET 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT age FROM users WHERE age > 20 ORDER BY age", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE score > 0 AND name LIKE 'E%'", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE score > ? AND name NOT LIKE 'a%'", [1_i64] of Grant::SQLiteEngine::Value},
    {"SELECT id, title FROM posts WHERE body LIKE '' OR title LIKE 'f%' ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT u.id, count(p.id) FROM users u JOIN posts p ON p.user_id = u.id WHERE u.age > 1 GROUP BY u.id ORDER BY u.id LIMIT 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM pairs ORDER BY b", [] of Grant::SQLiteEngine::Value},
    {"SELECT * FROM named", [] of Grant::SQLiteEngine::Value},
    # An unknown collation fails only where code generation looks it up:
    # key infos first (last one wins), then WHERE and the result set.
    {"SELECT name COLLATE nope FROM users ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT name == 'a' COLLATE c1, name == 'b' COLLATE c2 FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE name = 'a' COLLATE c1 ORDER BY email COLLATE c2", [] of Grant::SQLiteEngine::Value},
    {"SELECT id, email COLLATE c2 FROM users ORDER BY 1 COLLATE c1, 2", [] of Grant::SQLiteEngine::Value},
    {"SELECT max(name COLLATE c1), email COLLATE c2 FROM users", [] of Grant::SQLiteEngine::Value},
    {"SELECT age FROM users GROUP BY age COLLATE c1 ORDER BY name COLLATE c2", [] of Grant::SQLiteEngine::Value},
    {"SELECT (id COLLATE nose, age) IN (SELECT id, age FROM users) FROM users", [] of Grant::SQLiteEngine::Value},
    # count(*) over a UNION ALL subquery never codes its SELECTs' columns.
    {"SELECT id FROM users WHERE (SELECT count(*) FROM (SELECT 1 UNION ALL SELECT sum(users.age))) ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE (SELECT count(*) FROM (SELECT sum(users.age))) ORDER BY id", [] of Grant::SQLiteEngine::Value},
    {"WITH RECURSIVE c(i) AS (SELECT * UNION ALL SELECT i + 1 FROM c WHERE i < 3) SELECT i FROM c", [] of Grant::SQLiteEngine::Value},
    # Scan terms decided from the stored record (ScanTest): numbers against
    # numbers, a REAL column holding an integer, NULL, IS, text against a
    # number, and literal-prefix LIKE on a NOCASE column.
    {"SELECT id, score FROM users WHERE score > ? AND age >= ?", [3_i64, 17.5] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE ? <= score", [3_i64] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE score IS ? OR id = 4", [3.0] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age IS NOT ? AND score < 100", [36_i64] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM users WHERE age > ?", ["20"] of Grant::SQLiteEngine::Value},
    {"SELECT id, name FROM users WHERE name LIKE ? AND age > 1", ["a%"] of Grant::SQLiteEngine::Value},
    {"SELECT id FROM posts WHERE rank > ? AND title LIKE 'F%'", [5_i64] of Grant::SQLiteEngine::Value},
    {"SELECT id, flag FROM users WHERE flag = ? AND name NOT LIKE ?", [1_i64, "c%"] of Grant::SQLiteEngine::Value},
  ]
end

describe "Grant::SQLiteEngine::Query SELECT" do
  directory = Path[Dir.tempdir] / "grant-query-spec-#{Process.pid}"
  Dir.mkdir_p(directory)
  path = (directory / "fixture.db").to_s
  oracle = SQLiteQueryOracle::Connection.new(path)
  if message = oracle.exec(SelectSpecFixture::SETUP)
    raise "fixture setup failed: #{message}"
  end
  database = Grant::SQLiteEngine::Database.open(path)
  session = Grant::SQLiteEngine::Query::Session.new(database)

  # The engine follows C SQLite 3.51.0; these cases show behavior older
  # libraries lack (OP_IfEmpty before INTERSECT and EXCEPT; quote() of an
  # infinity as 9.0e+999).
  reference_only = {"SELECT 1 WHERE 0 INTERSECT SELECT abs(-9223372036854775807 - 1)", "SELECT quote(1e999), quote(-1e999), quote(0.1)"}
  library_is_reference = SQLiteSQLOracle.version.split(' ').first.split('.').map(&.to_i) >= [3, 51, 0]

  SelectSpecFixture::QUERIES.each do |(sql, parameters)|
    if reference_only.includes?(sql) && !library_is_reference
      pending "returns C SQLite 3.51.0's result for #{sql} (the linked libsqlite3 is #{SQLiteSQLOracle.version.split(' ').first})"
      next
    end
    it "returns C SQLite's result for #{sql}" do
      expected = oracle.query(sql, parameters)
      actual = SQLiteQueryOracle.engine_query(session, sql, parameters)
      ordered = sql.includes?("ORDER BY") && !sql.includes?("(SELECT 1 FROM users ORDER BY")
      difference = SQLiteQueryOracle.difference(expected, actual, ordered)
      difference.should be_nil
    end
  end

  it "raises UnsupportedSQL naming milestone G6 for JSON functions" do
    expect_raises(Grant::SQLiteEngine::UnsupportedSQL, /G6/) do
      session.prepare("SELECT json_valid('{}')")
    end
  end

  describe "#progress_handler" do
    it "stops a running statement with interrupted when the handler returns true" do
      calls = 0
      session.progress_handler(5) { (calls += 1) >= 2 }
      outcome = SQLiteQueryOracle.engine_query(session, "SELECT count(*) FROM users, users, users, users", [] of Grant::SQLiteEngine::Value)
      session.clear_progress_handler
      outcome.error.should eq("interrupted")
      calls.should eq(2)
    end

    it "lets the statement finish while the handler returns false" do
      session.progress_handler(1) { false }
      outcome = SQLiteQueryOracle.engine_query(session, "SELECT count(*) FROM users", [] of Grant::SQLiteEngine::Value)
      session.clear_progress_handler
      outcome.error.should be_nil
    end
  end
end
