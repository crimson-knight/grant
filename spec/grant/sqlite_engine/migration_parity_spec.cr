require "spec"
require "../../support/sqlite_engine/migration_differential"

# What common migrations (Amber V2's generators, Grant's migrator, Rails,
# Django, Laravel, Prisma, Ecto) see on Grant's engine, as C SQLite 3.51.0
# answers. Each example pins one difference the migration differential
# found and the engine now matches; the corpus example replays every
# migration of spec/grant/sqlite_engine/migrations against the linked C
# library.
module MigrationParitySpec
  alias Value = Grant::SQLiteEngine::Value

  # The outcomes of *statements*, in order, on a fresh engine database.
  def self.outcomes(statements : Array(String)) : Array(SQLiteQueryOracle::Outcome)
    directory = File.join(Dir.tempdir, "grant-migration-parity-#{Process.pid}")
    FileUtils.rm_rf(directory)
    Dir.mkdir_p(directory)
    session = SQLiteWriteOracle::Pair.open_session(File.join(directory, "engine.db"))
    begin
      statements.map do |sql|
        session.begin_statement_read
        begin
          SQLiteQueryOracle.engine_query(session, sql)
        ensure
          session.end_statement_read
        end
      end
    ensure
      session.database.close
      FileUtils.rm_rf(directory)
    end
  end

  def self.last(statements : Array(String)) : SQLiteQueryOracle::Outcome
    outcomes(statements).last
  end

  def self.rows(statements : Array(String)) : Array(Array(Value))
    outcome = last(statements)
    raise "#{statements.last}: #{outcome.error}" if outcome.error
    outcome.list_of_rows
  end

  def self.error(statements : Array(String)) : String?
    last(statements).error
  end
end

private alias EngineValue = Grant::SQLiteEngine::Value

describe "Grant::SQLiteEngine common migrations" do
  it "reports a standard declared type in upper case in PRAGMA table_info, as build.c stores it" do
    rows = MigrationParitySpec.rows([
      "CREATE TABLE posts (id integer PRIMARY KEY, body text, n Int, r real, b blob, a any, v varchar(20), f boolean, t \"Text\", q \"my type\", w [Blob], k \"varchar\"(10))",
      "PRAGMA table_info(posts)",
    ])
    rows.map { |row| row[2] }.should eq(["INTEGER", "TEXT", "INT", "REAL", "BLOB", "ANY", "varchar(20)", "boolean", "TEXT", "my type", "BLOB", "varchar"])
  end

  it "lists every table with pragma_table_list and no argument, as Rails 7.1+ asks" do
    statements = [
      "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT)",
      "CREATE TABLE settings (key TEXT PRIMARY KEY, value ANY) STRICT, WITHOUT ROWID",
      "CREATE VIEW emails AS SELECT id, email, upper(email) AS shout FROM users",
    ]
    MigrationParitySpec.rows(statements + ["SELECT * FROM pragma_table_list ORDER BY schema, name"]).should eq([
      ["main", "emails", "view", 3_i64, 0_i64, 0_i64],
      ["main", "settings", "table", 2_i64, 1_i64, 1_i64],
      ["main", "sqlite_schema", "table", 5_i64, 0_i64, 0_i64],
      ["main", "sqlite_sequence", "table", 2_i64, 0_i64, 0_i64],
      ["main", "users", "table", 2_i64, 0_i64, 0_i64],
      ["temp", "sqlite_temp_schema", "table", 5_i64, 0_i64, 0_i64],
    ].map(&.map(&.as(EngineValue))))
    rails = "SELECT name FROM pragma_table_list WHERE schema <> 'temp' AND name NOT IN ('sqlite_sequence', 'sqlite_schema') " \
            "AND name = 'users' AND type IN ('table')"
    MigrationParitySpec.rows(statements + [rails]).should eq([["users"] of EngineValue])
    MigrationParitySpec.rows(statements + ["PRAGMA main.table_list(settings)"]).should eq([["main", "settings", "table", 2_i64, 1_i64, 1_i64] of EngineValue])
    MigrationParitySpec.rows(statements + ["PRAGMA temp.table_list"]).should eq([["temp", "sqlite_temp_schema", "table", 5_i64, 0_i64, 0_i64] of EngineValue])
  end

  it "calls a function written name(*) with no arguments, as Rails' SELECT sqlite_version(*) does" do
    MigrationParitySpec.rows(["SELECT sqlite_version(*)"]).should eq([["3.51.0"] of EngineValue])
    MigrationParitySpec.error(["SELECT upper(*)"]).should eq("wrong number of arguments to function upper()")
    MigrationParitySpec.error(["SELECT nosuch(*)"]).should eq("no such function: nosuch")
  end

  it "names an unnamed CHECK by its text passed through sqlite3Dequote (Django and Laravel quote the column)" do
    setup = "CREATE TABLE entries (rating integer NOT NULL CHECK (\"rating\" >= 0), status varchar CHECK (\"status\" IN ('a', 'b')), " \
            "n int CHECK (n > 0), m int, CHECK ((\"m\") > 0))"
    MigrationParitySpec.error([setup, "INSERT INTO entries (rating) VALUES (-1)"]).should eq("CHECK constraint failed: rating")
    MigrationParitySpec.error([setup, "INSERT INTO entries (rating, status) VALUES (1, 'c')"]).should eq("CHECK constraint failed: status")
    MigrationParitySpec.error([setup, "INSERT INTO entries (rating, n) VALUES (1, 0)"]).should eq("CHECK constraint failed: n > 0")
    MigrationParitySpec.error([setup, "INSERT INTO entries (rating, m) VALUES (1, 0)"]).should eq("CHECK constraint failed: (\"m\") > 0")
  end

  it "checks STRICT tables as C does: datatypes when created, its messages, and NOT NULL primary keys" do
    MigrationParitySpec.error(["CREATE TABLE s (a VARCHAR(10)) STRICT"]).should eq("unknown datatype for s.a: \"VARCHAR(10)\"")
    MigrationParitySpec.error(["CREATE TABLE s (a) STRICT"]).should eq("missing datatype for s.a")
    MigrationParitySpec.error(["CREATE TABLE s (a \"INT\", b Integer) STRICT"]).should be_nil
    setup = "CREATE TABLE s (key TEXT PRIMARY KEY, n INT, r REAL)"
    MigrationParitySpec.error(["#{setup} STRICT", "INSERT INTO s VALUES ('k', 'x', 1)"]).should eq("cannot store TEXT value in INT column s.n")
    MigrationParitySpec.error(["#{setup} STRICT", "INSERT INTO s VALUES ('k', '1.5', 1)"]).should eq("cannot store REAL value in INT column s.n")
    MigrationParitySpec.error(["#{setup} STRICT", "INSERT INTO s VALUES (NULL, 1, 1)"]).should eq("NOT NULL constraint failed: s.key")
    MigrationParitySpec.rows(["#{setup} STRICT", "PRAGMA table_info(s)"]).map { |row| row[3] }.should eq([1_i64, 0_i64, 0_i64])
    MigrationParitySpec.rows(["CREATE TABLE w (k TEXT PRIMARY KEY, v) WITHOUT ROWID", "PRAGMA table_info(w)"]).map { |row| row[3] }.should eq([1_i64, 0_i64])
    MigrationParitySpec.rows(["CREATE TABLE r (id INTEGER PRIMARY KEY, v INT) STRICT", "PRAGMA table_info(r)"]).map { |row| row[3] }.should eq([0_i64, 0_i64])
  end

  it "turns PRAGMA defer_foreign_keys off when a transaction ends, as Prisma's and Rails' table rebuilds rely on" do
    MigrationParitySpec.outcomes([
      "CREATE TABLE t (a)",
      "BEGIN", "PRAGMA defer_foreign_keys = ON", "INSERT INTO t VALUES (1)", "PRAGMA defer_foreign_keys", "COMMIT",
      "PRAGMA defer_foreign_keys",
      "PRAGMA defer_foreign_keys = ON", "INSERT INTO t VALUES (2)", "PRAGMA defer_foreign_keys",
      "BEGIN", "PRAGMA defer_foreign_keys = ON", "ROLLBACK", "PRAGMA defer_foreign_keys",
    ]).compact_map(&.list_of_rows.first?).should eq([[1_i64], [0_i64], [0_i64], [0_i64]].map(&.map(&.as(EngineValue))))
  end

  it "sets changes() as sqlite3FkDropTable does when DROP TABLE drops a child with deferred foreign keys" do
    setup = [
      "CREATE TABLE p (id INTEGER PRIMARY KEY)",
      "CREATE TABLE c (id INTEGER PRIMARY KEY, p_id REFERENCES p ON DELETE CASCADE)",
      "INSERT INTO p VALUES (1), (2), (3)",
      "INSERT INTO c VALUES (1, 1), (2, 2)",
      "PRAGMA foreign_keys = ON",
    ]
    MigrationParitySpec.rows(setup + ["DROP TABLE c", "SELECT changes()"]).should eq([[2_i64] of EngineValue])
    MigrationParitySpec.rows(setup + ["PRAGMA defer_foreign_keys = ON", "DROP TABLE c", "SELECT changes()"]).should eq([[0_i64] of EngineValue])
    MigrationParitySpec.rows(setup + ["DROP TABLE p", "SELECT changes(), total_changes()"]).should eq([[3_i64, 10_i64] of EngineValue])
  end

  it "lists indexes as sqlite3CreateIndex links them: REPLACE indexes last, a WITHOUT ROWID key included" do
    rows = MigrationParitySpec.rows([
      "CREATE TABLE a (id INTEGER PRIMARY KEY, code TEXT UNIQUE, name TEXT, day TEXT, UNIQUE (name, day) ON CONFLICT REPLACE)",
      "CREATE INDEX a_day ON a (day) WHERE day IS NOT NULL",
      "PRAGMA index_list(a)",
    ])
    rows.should eq([
      [0_i64, "a_day", 0_i64, "c", 1_i64],
      [1_i64, "sqlite_autoindex_a_1", 1_i64, "u", 0_i64],
      [2_i64, "sqlite_autoindex_a_2", 1_i64, "u", 0_i64],
    ].map(&.map(&.as(EngineValue))))
    rows = MigrationParitySpec.rows([
      "CREATE TABLE w (id TEXT NOT NULL PRIMARY KEY, title TEXT UNIQUE) WITHOUT ROWID",
      "CREATE INDEX w_title ON w (lower(title))",
      "PRAGMA index_list(w)",
    ])
    rows.should eq([
      [0_i64, "w_title", 0_i64, "c", 0_i64],
      [1_i64, "sqlite_autoindex_w_2", 1_i64, "u", 0_i64],
      [2_i64, "sqlite_autoindex_w_1", 1_i64, "pk", 0_i64],
    ].map(&.map(&.as(EngineValue))))
  end

  it "fails ALTER TABLE when a view no longer resolves, as renameTestSchema does before it edits the schema" do
    setup = [
      "CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT)",
      "CREATE VIEW roster AS SELECT name FROM teams",
      "CREATE TABLE teams_new (id INTEGER PRIMARY KEY, name TEXT, city TEXT)",
      "DROP TABLE teams",
    ]
    MigrationParitySpec.error(setup + ["ALTER TABLE teams_new RENAME TO teams"]).should eq("error in view roster: no such table: main.teams")
    MigrationParitySpec.error(setup + ["ALTER TABLE teams_new RENAME COLUMN city TO town"]).should eq("error in view roster: no such table: main.teams")
    MigrationParitySpec.error(setup + ["ALTER TABLE teams_new DROP COLUMN city"]).should eq("error in view roster: no such table: main.teams")
  end

  it "reports DROP COLUMN's schema errors in sqlite_schema order, with C's hint for a double-quoted name" do
    books = "CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER, isbn TEXT, CONSTRAINT fk FOREIGN KEY (\"author_id\") REFERENCES authors (\"id\"))"
    MigrationParitySpec.error([books, "CREATE INDEX books_author ON books (\"author_id\")", "ALTER TABLE books DROP COLUMN author_id"])
      .should eq("error in table books after drop column: unknown column \"author_id\" in foreign key definition")
    MigrationParitySpec.error([books, "CREATE UNIQUE INDEX books_isbn ON books (\"isbn\")", "ALTER TABLE books DROP COLUMN isbn"])
      .should eq("error in index books_isbn after drop column: no such column: \"isbn\" - should this be a string literal in single-quotes?")
    MigrationParitySpec.error([books, "CREATE UNIQUE INDEX books_isbn ON books (isbn)", "ALTER TABLE books DROP COLUMN isbn"])
      .should eq("error in index books_isbn after drop column: no such column: isbn")
  end

  it "refuses to drop or alter the schema table by C's name for it" do
    MigrationParitySpec.error(["DROP TABLE sqlite_schema"]).should eq("table sqlite_master may not be dropped")
    MigrationParitySpec.error(["DROP TABLE IF EXISTS sqlite_master"]).should eq("table sqlite_master may not be dropped")
    MigrationParitySpec.error(["DROP TABLE temp.sqlite_master"]).should eq("table sqlite_temp_master may not be dropped")
    MigrationParitySpec.error(["ALTER TABLE sqlite_master RENAME TO x"]).should eq("table sqlite_master may not be altered")
    MigrationParitySpec.error(["ALTER TABLE sqlite_temp_schema ADD COLUMN y"]).should eq("table sqlite_temp_master may not be altered")
  end

  it "refuses subqueries, parameters and non-deterministic functions in an index" do
    table = "CREATE TABLE t (a)"
    MigrationParitySpec.error([table, "CREATE INDEX i ON t (random())"]).should eq("non-deterministic functions prohibited in index expressions")
    MigrationParitySpec.error([table, "CREATE INDEX i ON t (sqlite_version())"]).should eq("non-deterministic functions prohibited in index expressions")
    MigrationParitySpec.error([table, "CREATE INDEX i ON t (a) WHERE random() > 0"]).should eq("non-deterministic functions prohibited in partial index WHERE clauses")
    MigrationParitySpec.error([table, "CREATE INDEX i ON t (a) WHERE a IN (SELECT 1)"]).should eq("subqueries prohibited in partial index WHERE clauses")
    MigrationParitySpec.error([table, "CREATE INDEX i ON t ((SELECT 1))"]).should eq("subqueries prohibited in index expressions")
    MigrationParitySpec.error([table, "CREATE INDEX i ON t (a + ?)"]).should eq("parameters prohibited in index expressions")
    MigrationParitySpec.error([table, "CREATE INDEX i ON t (a) WHERE a IN (1, 2)", "PRAGMA index_list(t)"]).should be_nil
  end

  it "names an unknown database as the statement wrote it" do
    MigrationParitySpec.error(["CREATE TABLE \"ns\".\"t\" (a)"]).should eq("unknown database \"ns\"")
    MigrationParitySpec.error(["CREATE TABLE ns.t (a)"]).should eq("unknown database ns")
    MigrationParitySpec.error(["PRAGMA \"ns\".user_version"]).should eq("unknown database \"ns\"")
  end

  # The corpus compared with C: SQLite 3.51.0 only, since error messages
  # and PRAGMA answers differ between releases.
  linked = SQLiteSQLOracle.version.split(' ').first
  if linked == "3.51.0"
    it "matches C SQLite 3.51.0 on the migration corpus, apart from the listed remaining differences" do
      report = MigrationDifferential.run(MigrationDifferential::CORPUS, File.join(Dir.tempdir, "grant-migration-corpus-#{Process.pid}"))
      report.counts["migrations"].should be > 20
      report.list_of_unexplained.should eq([] of String)
      report.list_of_unused_rules.map(&.needle).should eq([] of String)
    end
  else
    pending "matches C SQLite 3.51.0 on the migration corpus (the linked libsqlite3 is #{linked})"
  end
end
