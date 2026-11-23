require "spec"
require "digest/sha256"
require "../../../../src/grant/sqlite_engine"

private alias SQL = Grant::SQLiteEngine::SQL

private def parse(sql : String) : SQL::Statement
  statement = SQL::Parser.parse(sql)
  raise "no statement in #{sql.inspect}" unless statement
  statement
end

private def select_of(sql : String) : SQL::SelectStatement
  parse(sql).as(SQL::SelectStatement)
end

private def first_expression(sql : String) : SQL::Expression
  core = select_of(sql).cores.first.as(SQL::SelectClause)
  core.columns.first.as(SQL::ExpressionColumn).expression
end

private def parse_error(sql : String) : SQL::ParseError
  SQL::Parser.parse(sql)
  raise "expected a parse error for #{sql[0, 200].inspect}"
rescue error : SQL::ParseError
  error
end

private def round_trips(sql : String) : Nil
  statement = parse(sql)
  printed = statement.to_sql
  reparsed = SQL::Parser.parse(printed)
  reparsed.should eq(statement), "#{sql}\nprinted as\n#{printed}"
end

private def kinds(sql : String) : Array(SQL::TokenKind)
  tokenizer = SQL::Tokenizer.new(sql)
  list_of_kinds = [] of SQL::TokenKind
  loop do
    token = tokenizer.next_token
    break if token.kind.end_of_input?
    list_of_kinds << token.kind
  end
  list_of_kinds
end

describe SQL::Tokenizer do
  it "recognizes keywords without regard to case and quoted names as identifiers" do
    kinds(%(select "from" FROM [where] `x`)).should eq([
      SQL::TokenKind::Select, SQL::TokenKind::Identifier, SQL::TokenKind::From,
      SQL::TokenKind::Identifier, SQL::TokenKind::Identifier,
    ])
  end

  it "splits operators, numbers, blobs and parameters as tokenize.c does" do
    kinds("a->>'$.b' <> 1.5e3 || x'0aff' ?7 :name $tcl::var(x) @at 0x1F 1_000 .5").should eq([
      SQL::TokenKind::Identifier, SQL::TokenKind::Pointer, SQL::TokenKind::String,
      SQL::TokenKind::NotEqual, SQL::TokenKind::Float, SQL::TokenKind::Concat, SQL::TokenKind::Blob,
      SQL::TokenKind::Variable, SQL::TokenKind::Variable, SQL::TokenKind::Variable,
      SQL::TokenKind::Variable, SQL::TokenKind::Integer, SQL::TokenKind::QuotedNumber, SQL::TokenKind::Float,
    ])
  end

  it "skips comments, including Grant's /*+ hint */ comments and an unterminated block comment" do
    kinds("SELECT /*+ INDEX(users idx) */ 1 -- trailing\n , 2 /* open").should eq([
      SQL::TokenKind::Select, SQL::TokenKind::Integer, SQL::TokenKind::Comma, SQL::TokenKind::Integer,
    ])
  end

  it "stops at a NUL byte as a C string does" do
    kinds("SELECT 1\u0000 garbage ''").should eq([SQL::TokenKind::Select, SQL::TokenKind::Integer])
  end

  it "makes WINDOW, OVER and FILTER keywords only where SQLite does" do
    kinds("over filter window").should eq([SQL::TokenKind::Identifier] * 3)
    kinds("f() OVER w").should contain(SQL::TokenKind::Over)
    kinds("f() FILTER (").should contain(SQL::TokenKind::Filter)
    kinds("WINDOW w AS").first.should eq(SQL::TokenKind::Window)
  end
end

describe SQL::Parser do
  it "returns nil for text with no statement and skips leading semicolons" do
    SQL::Parser.parse("").should be_nil
    SQL::Parser.parse(" ;; -- nothing\n").should be_nil
    parse(";;SELECT 1").should be_a(SQL::SelectStatement)
  end

  it "parses only the first statement, as sqlite3_prepare_v2 does" do
    parse("SELECT 1; this is not SQL").should be_a(SQL::SelectStatement)
    SQL::Parser.parse_all("SELECT 1; SELECT 2;").size.should eq(2)
  end

  it "binds operators with SQLite's precedence" do
    expression = first_expression("SELECT 1 + 2 * 3 = 7 AND NOT a OR b")
    expression.to_sql.should eq("(((1 + (2 * 3)) = 7) AND (NOT a)) OR b")
    first_expression("SELECT -a COLLATE nocase || b").to_sql.should eq("((-a) COLLATE nocase) || b")
    first_expression("SELECT NOT a = b").to_sql.should eq("NOT (a = b)")
    first_expression("SELECT a BETWEEN 1 AND 2 AND c").to_sql.should eq("(a BETWEEN 1 AND 2) AND c")
    first_expression("SELECT a = b NOT NULL").to_sql.should eq("(a = b) NOT NULL")
    first_expression("SELECT x NOT LIKE 'a%' ESCAPE '!'").to_sql.should eq("x NOT LIKE 'a%' ESCAPE '!'")
  end

  it "lets keywords stand as names where parse.y falls back to ID" do
    query = select_of("SELECT key, end, replace(a, 'b', 'c') AS offset FROM t AS do WHERE match MATCH 'x'")
    core = query.cores.first.as(SQL::SelectClause)
    core.columns.size.should eq(3)
    parse_error("SELECT select FROM t").message.should eq(%(near "select": syntax error))
    parse_error("SELECT cast FROM t").message.should eq(%(near "FROM": syntax error))
  end

  it "numbers parameters as sqlite3ExprAssignVarNumber does" do
    query = select_of("SELECT ?, :a, ?5, :a, ?")
    core = query.cores.first.as(SQL::SelectClause)
    numbers = core.columns.map { |column| column.as(SQL::ExpressionColumn).expression.as(SQL::Parameter).number }
    numbers.should eq([1, 2, 5, 2, 6])
    parse_error("SELECT ?0").message.should eq("variable number must be between ?1 and ?32766")
    parse_error("SELECT ?32767").message.should eq("variable number must be between ?1 and ?32766")
  end

  it "parses the statements Grant issues" do
    [
      %(SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?),
      %(CREATE TABLE IF NOT EXISTS "posts" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "title" VARCHAR(255) NOT NULL DEFAULT '', "user_id" BIGINT REFERENCES "users" ("id") ON DELETE CASCADE, UNIQUE ("title", "user_id"))),
      %(INSERT INTO "posts" ("title") VALUES (?), (?) ON CONFLICT ("title") DO UPDATE SET "title" = excluded."title" RETURNING "id"),
      %(WITH RECURSIVE tree(id) AS (SELECT id FROM nodes WHERE parent_id IS NULL UNION ALL SELECT n.id FROM nodes n JOIN tree ON n.parent_id = tree.id) SELECT * FROM tree ORDER BY id NULLS LAST LIMIT 10 OFFSET 5),
      %(UPDATE "posts" SET "title" = t.title FROM (SELECT 1 AS title) AS t WHERE "posts"."id" = ?),
      %(DELETE FROM "posts" WHERE "id" IN (SELECT "id" FROM "posts" LIMIT ?)),
      %(ALTER TABLE "posts" RENAME COLUMN "title" TO "headline"),
      %(SELECT * FROM pragma_table_xinfo('posts')),
      %(SAVEPOINT grant_savepoint_1),
      %(RELEASE SAVEPOINT grant_savepoint_1),
      %(BEGIN IMMEDIATE TRANSACTION),
      %(EXPLAIN QUERY PLAN SELECT * FROM "posts" INDEXED BY idx WHERE id = 1),
      %(CREATE UNIQUE INDEX IF NOT EXISTS idx ON posts (lower(title) COLLATE NOCASE DESC) WHERE title IS NOT NULL),
      %(SELECT sum(x) FILTER (WHERE x > 0) OVER (PARTITION BY y ORDER BY z ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t),
      %(SELECT CASE WHEN a THEN 1 ELSE 2 END, CAST(b AS DECIMAL(10, 2)), EXISTS (SELECT 1), x REGEXP '^a' FROM t),
      %(CREATE TRIGGER tr AFTER UPDATE OF a, b ON t FOR EACH ROW WHEN new.a > 0 BEGIN INSERT INTO log VALUES (new.a); DELETE FROM t2 WHERE x = old.b; END),
      %(PRAGMA main.foreign_keys = ON),
      %(ATTACH DATABASE ':memory:' AS other),
    ].each { |sql| round_trips(sql) }
  end

  it "raises SQLite's messages for syntax errors and unrecognized tokens" do
    parse_error("SELECT 1 +").message.should eq("incomplete input")
    parse_error("SELECT 1 FROM").message.should eq("incomplete input")
    parse_error("SELECT * FROM t WHERE").message.should eq("incomplete input")
    parse_error("SELECT 1 + ;").message.should eq(%(near ";": syntax error))
    parse_error("SELECT 'abc").message.should eq(%(unrecognized token: "'abc"))   # secret-scan-gate:allow (SQL tokenizer test text)
    parse_error("SELECT 12abc").message.should eq(%(unrecognized token: "12abc")) # secret-scan-gate:allow (SQL tokenizer test text)
    parse_error("SELECT 1__0").message.should eq(%(unrecognized token: "1__0"))   # secret-scan-gate:allow (SQL tokenizer test text)
    parse_error("\vSELECT 1").message.should eq(%(unrecognized token: "\v"))      # secret-scan-gate:allow (SQL tokenizer test text)
    SQL::Parser.parse(" \vSELECT 1").should_not be_nil
  end

  it "raises the errors SQLite's grammar actions raise" do
    parse_error("CREATE TABLE t (a INTEGER PRIMARY KEY, b PRIMARY KEY)").message
      .should eq(%(table "t" has more than one primary key))
    parse_error("CREATE TABLE t (a TEXT PRIMARY KEY AUTOINCREMENT)").message
      .should eq("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY")
    parse_error("CREATE TABLE t (a, a)").message.should eq("duplicate column name: a")
    parse_error("CREATE TABLE t (a DEFAULT (b + 1))").message.should eq("default value of column [a] is not constant")
    parse_error("CREATE TABLE t (a) WITHOUT foo").message.should eq("unknown table option: foo")
    parse_error("CREATE TABLE sqlite_x (a)").message.should eq("object name reserved for internal use: sqlite_x")
    parse_error("SELECT 1 ORDER BY 1 UNION SELECT 2").message.should eq("ORDER BY clause should come after UNION not before")
    parse_error("SELECT * FROM a LEFT INNER JOIN b").message.should eq("unknown join type: LEFT INNER")
    parse_error("SELECT * FROM a ON 1").message.should eq("a JOIN clause is required before ON")
    parse_error("VALUES (1), (1, 2)").message.should eq("all VALUES must have the same number of terms")
    parse_error("WITH c(a COLLATE nocase) AS (SELECT 1) SELECT * FROM c").message
      .should eq(%(syntax error after column name "a"))
  end

  it "accepts an INTEGER PRIMARY KEY with AUTOINCREMENT however the type is quoted" do
    parse("CREATE TABLE t (a \"INTEGER\" PRIMARY KEY AUTOINCREMENT)").should be_a(SQL::CreateTable)
    parse("CREATE TABLE t (a INTEGER, PRIMARY KEY (a AUTOINCREMENT))").should be_a(SQL::CreateTable)
  end

  it "stops at SQLite's expression depth and the parser's nesting limit" do
    deep = "SELECT " + ("1 + " * 1000) + "1"
    parse_error(deep).message.should eq("Expression tree is too large (maximum depth 1000)")
    shallow = "SELECT " + ("1 + " * 999) + "1"
    parse(shallow).should be_a(SQL::SelectStatement)
    nested = "SELECT " + ("(" * 5_000) + "1" + (")" * 5_000)
    parse_error(nested).message.should eq("Expression tree is too large (maximum depth 1000)")
  end

  it "rejects text longer than the statement length limit" do
    parse_error("SELECT '" + ("a" * SQL::Limits::MAX_SQL_LENGTH) + "'").message.should eq("string or blob too big")
  end
end

describe "Grant::SQLiteEngine::SQL over Grant's statement corpus" do
  corpus = Path[__DIR__] / ".." / "corpus" / "grant_sql_corpus.txt"

  it "reads the committed corpus by its sha256" do
    Digest::SHA256.hexdigest(File.read(corpus)).should eq(
      "dee21f555d062d5c8b5f7dd51c771e836d0fb7a2742338d1d1124c58a37d7db3")
  end

  it "parses every statement and prints each back to SQL that parses to an equal tree" do
    statements = File.read_lines(corpus)
    failures = [] of String
    statements.each do |sql|
      statement = SQL::Parser.parse(sql)
      if statement.nil?
        failures << "no statement: #{sql}"
        next
      end
      printed = statement.to_sql
      failures << "round trip: #{sql}\n  printed: #{printed}" unless SQL::Parser.parse(printed) == statement
    rescue error : SQL::ParseError
      failures << "#{error.message}: #{sql}"
    end
    STDOUT.puts "\n  corpus: #{statements.size} statements, #{statements.size - failures.size} parsed and round-tripped"
    failures.first(20).each { |failure| STDOUT.puts "    #{failure}" }
    failures.should be_empty
  end
end
