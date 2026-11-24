# Runs each statement of milestone G6's surface (catalog, pragmas, EXPLAIN
# QUERY PLAN, ALTER TABLE, generated columns, JSON and date/time functions,
# ANALYZE, VACUUM, backup) through Grant's engine and through libsqlite3,
# each case on its own fresh database, and reports every case where the
# two differ in result code, column names or rows.
#
#   crystal-alpha build --release scripts/sqlite_engine_g6_probe.cr -o g6probe
#   ./g6probe REPORT_DIR
#
# Link a pinned libsqlite3 with --link-flags "-L DIR -Wl,-rpath,DIR".
require "file_utils"
require "../src/grant/drivers/sqlite3/sqlite3/type"
require "../src/grant/drivers/sqlite3/sqlite3/flags"
require "../src/grant/drivers/sqlite3/sqlite3/engine"
require "../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../src/grant/drivers/sqlite3/sqlite3/engine/lib_sqlite3_engine"

alias ProbeEngine = Grant::SQLite3::Engine

SETUP = <<-SQL
  CREATE TABLE authors(id INTEGER PRIMARY KEY, first_name TEXT NOT NULL, email TEXT UNIQUE, born_at TEXT, meta TEXT);
  CREATE TABLE posts(id INTEGER PRIMARY KEY AUTOINCREMENT, author_id INTEGER REFERENCES authors(id) ON DELETE CASCADE,
    title TEXT DEFAULT 'untitled', body TEXT, score REAL, created_at TEXT, word_count INTEGER GENERATED ALWAYS AS (length(body)) STORED,
    slug TEXT GENERATED ALWAYS AS (lower(replace(title, ' ', '-'))) STORED);
  CREATE INDEX index_posts_on_author_id ON posts(author_id);
  CREATE INDEX index_posts_on_score_and_title ON posts(score DESC, title COLLATE NOCASE);
  CREATE UNIQUE INDEX index_authors_on_lower_email ON authors(lower(email));
  CREATE VIEW post_titles AS SELECT id, title FROM posts;
  INSERT INTO authors VALUES (1, 'Ada', 'ada@example.com', '2026-11-24 10:11:12.123456', '{"tags":["a","b"],"n":3,"o":{"k":null},"f":1.5}');
  INSERT INTO authors VALUES (2, 'Brian', 'bk@example.com', '1999-12-31 23:59:59.999999', '[1,2,{"x":"y"}]');
  INSERT INTO posts(author_id, title, body, score, created_at) VALUES (1, 'Hello World', 'abcdef', 1.5, '2026-11-24 00:00:00.000000');
  INSERT INTO posts(author_id, title, body, score, created_at) VALUES (2, 'Second Post', NULL, NULL, '2026-01-31 12:00:00.000001');
SQL

# Each case: a name, extra setup, and the statement whose rows are compared.
CASES = [
  # catalog and pragmas
  {"sqlite_master", "", "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name"},
  {"sqlite_schema", "", "SELECT type, name FROM sqlite_schema WHERE type = 'index' ORDER BY name"},
  {"pragma table_info", "", "PRAGMA table_info(posts)"},
  {"pragma table_xinfo", "", "PRAGMA table_xinfo(posts)"},
  {"pragma_table_info tvf", "", "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info('authors')"},
  {"pragma index_list", "", "PRAGMA index_list(posts)"},
  {"pragma index_list authors", "", "PRAGMA index_list(authors)"},
  {"pragma index_info", "", "PRAGMA index_info(index_posts_on_score_and_title)"},
  {"pragma index_xinfo", "", "PRAGMA index_xinfo(index_posts_on_score_and_title)"},
  {"pragma index_info expr", "", "PRAGMA index_info(index_authors_on_lower_email)"},
  {"pragma foreign_key_list", "", "PRAGMA foreign_key_list(posts)"},
  {"pragma_index_list join", "", "SELECT m.name, il.name, il.\"unique\" FROM sqlite_master m JOIN pragma_index_list(m.name) il WHERE m.type = 'table' ORDER BY 1, 2"},
  {"pragma user_version", "PRAGMA user_version = 7;", "PRAGMA user_version"},
  {"pragma application_id", "PRAGMA application_id = 42;", "PRAGMA application_id"},
  {"pragma schema_version", "", "PRAGMA schema_version"},
  {"pragma page_size", "", "PRAGMA page_size"},
  {"pragma page_count", "", "PRAGMA page_count"},
  {"pragma freelist_count", "", "PRAGMA freelist_count"},
  {"pragma integrity_check", "", "PRAGMA integrity_check"},
  {"pragma quick_check", "", "PRAGMA quick_check"},
  {"pragma foreign_key_check", "PRAGMA foreign_keys=OFF; INSERT INTO posts(author_id, title) VALUES (99, 'orphan');", "PRAGMA foreign_key_check"},
  {"pragma database_list", "", "SELECT seq, name FROM pragma_database_list"},
  {"pragma journal_mode", "", "PRAGMA journal_mode"},
  {"pragma auto_vacuum", "", "PRAGMA auto_vacuum"},
  {"pragma encoding", "", "PRAGMA encoding"},
  {"pragma optimize", "", "PRAGMA optimize"},
  # EXPLAIN QUERY PLAN: the columns must match; detail text may differ
  {"eqp columns", "", "SELECT count(*) FROM (SELECT 1)"},
  # ALTER TABLE
  {"alter add column", "ALTER TABLE authors ADD COLUMN nickname TEXT DEFAULT 'none';", "SELECT id, nickname FROM authors ORDER BY id"},
  {"alter add column sql", "ALTER TABLE authors ADD COLUMN nickname TEXT DEFAULT 'none';", "SELECT sql FROM sqlite_master WHERE name = 'authors'"},
  {"alter rename table", "ALTER TABLE posts RENAME TO articles;", "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name"},
  {"alter rename column", "ALTER TABLE authors RENAME COLUMN first_name TO given_name;", "SELECT sql FROM sqlite_master WHERE tbl_name = 'authors' ORDER BY name"},
  {"alter rename column idx", "ALTER TABLE posts RENAME COLUMN score TO rating;", "SELECT name, sql FROM sqlite_master WHERE tbl_name = 'posts' ORDER BY name"},
  {"alter drop column", "ALTER TABLE authors DROP COLUMN born_at;", "SELECT * FROM authors ORDER BY id"},
  {"alter drop column sql", "ALTER TABLE authors DROP COLUMN born_at;", "SELECT sql FROM sqlite_master WHERE name = 'authors'"},
  {"alter drop indexed column", "", "ALTER TABLE posts DROP COLUMN author_id"},
  # generated columns
  {"generated read", "", "SELECT id, word_count, slug FROM posts ORDER BY id"},
  {"generated after update", "UPDATE posts SET title = 'New Title', body = 'xy' WHERE id = 1;", "SELECT id, word_count, slug FROM posts ORDER BY id"},
  {"generated insert refused", "", "INSERT INTO posts(slug) VALUES ('x')"},
  {"generated virtual", "CREATE TABLE gv(a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL); INSERT INTO gv(a) VALUES (3), (NULL);", "SELECT a, b FROM gv ORDER BY rowid"},
  {"generated virtual where", "CREATE TABLE gv(a INTEGER, b INTEGER AS (a * 2)); INSERT INTO gv(a) VALUES (3), (4); UPDATE gv SET a = 10 WHERE b = 8;", "SELECT a, b FROM gv WHERE b > 5 ORDER BY b"},
  # JSON
  {"json_extract", "", "SELECT json_extract(meta, '$.tags[1]'), json_extract(meta, '$.n'), json_extract(meta, '$.o'), json_extract(meta, '$.f'), json_extract(meta, '$.missing') FROM authors ORDER BY id"},
  {"json arrows", "", "SELECT meta -> '$.tags', meta ->> '$.tags[0]', meta -> 'n', meta ->> 'f' FROM authors ORDER BY id"},
  {"json_type", "", "SELECT json_type(meta), json_type(meta, '$.n'), json_type(meta, '$.o.k'), json_type(meta, '$.f') FROM authors ORDER BY id"},
  {"json_valid", "", "SELECT json_valid('{}'), json_valid('{'), json_valid(NULL), json_valid('[1,]')"},
  {"json", "", "SELECT json(' { \"a\" : [1, 2.50, true, null] } ')"},
  {"json_object array", "", "SELECT json_object('a', 1, 'b', 'two', 'c', NULL, 'd', json('[1]')), json_array(1, 'x', NULL, 2.5)"},
  {"json_set family", "", "SELECT json_set(meta, '$.n', 4, '$.new', 'v'), json_insert(meta, '$.n', 9, '$.z', 1), json_replace(meta, '$.n', 0, '$.zz', 1), json_remove(meta, '$.tags[0]', '$.o') FROM authors WHERE id = 1"},
  {"json_array_length", "", "SELECT json_array_length(meta, '$.tags'), json_array_length('[1,2,3]'), json_array_length('{}') FROM authors WHERE id = 1"},
  {"json_each", "", "SELECT key, value, type, atom, path FROM json_each((SELECT meta FROM authors WHERE id = 1))"},
  {"json_each array", "", "SELECT a.id, j.key, j.value FROM authors a, json_each(a.meta) j WHERE a.id = 2"},
  {"json_tree", "", "SELECT key, type, atom, fullkey, path FROM json_tree((SELECT meta FROM authors WHERE id = 1))"},
  {"json_group", "", "SELECT json_group_array(first_name), json_group_object(first_name, id) FROM authors"},
  {"json_patch quote", "", "SELECT json_patch('{\"a\":1,\"b\":2}', '{\"b\":null,\"c\":3}'), json_quote('x\"y'), json_quote(3.5)"},
  {"json malformed", "", "SELECT json_extract('{bad', '$.a')"},
  {"json_each predicate", "", "SELECT id FROM authors WHERE EXISTS (SELECT 1 FROM json_each(authors.meta, '$.tags') WHERE value = 'b')"},
  # date and time on Grant's six-digit format
  {"date funcs", "", "SELECT date(born_at), time(born_at), datetime(born_at), julianday(born_at), unixepoch(born_at) FROM authors ORDER BY id"},
  {"strftime", "", "SELECT strftime('%Y-%m-%d %H:%M:%f', born_at), strftime('%s', born_at), strftime('%j %w %W %u', born_at), strftime('%%') FROM authors ORDER BY id"},
  {"modifiers", "", "SELECT datetime(born_at, '+1 day'), datetime(born_at, 'start of month'), date(born_at, 'weekday 0'), datetime(born_at, '-3 hours', '+30 minutes'), date(born_at, '+1 month') FROM authors ORDER BY id"},
  {"modifiers 2", "", "SELECT date('2026-01-31', '+1 month'), date('2024-02-29', '+1 year'), datetime(1700000000, 'unixepoch'), datetime(2460000.5), date('2026-11-24', 'start of year', '+45 days')"},
  {"subsec", "", "SELECT datetime(born_at, 'subsec'), unixepoch(born_at, 'subsec') FROM authors ORDER BY id"},
  {"date compare", "", "SELECT id FROM posts WHERE created_at >= '2026-01-31 12:00:00.000001' AND datetime(created_at) < datetime('2026-12-01') ORDER BY id"},
  {"date invalid", "", "SELECT date('not a date'), datetime('2026-13-01'), julianday(NULL), date('2026-02-30')"},
  {"timediff", "", "SELECT timediff('2026-11-24 10:00:00', '2026-01-01 00:00:00')"},
  {"strftime all", "", "SELECT strftime('%d|%e|%f|%F|%G|%g|%H|%I|%j|%J|%k|%l|%m|%M|%p|%P|%R|%s|%S|%T|%u|%U|%V|%w|%W|%Y|%%', born_at) FROM authors ORDER BY id"},
  {"modifiers 3", "", "SELECT datetime(born_at, '+0001-01-01 01:01:01.001', 'subsec'), date(born_at, '+1 year', 'floor'), date(born_at, '-1.5 months', 'ceiling'), datetime(born_at, '-12:30'), julianday(born_at, 'start of day') FROM authors ORDER BY id"},
  {"time values", "", "SELECT datetime('2026-11-24T10:11:12.5+02:30'), datetime('10:11'), datetime(1700000000, 'auto'), date(0, 'julianday'), datetime('9999-12-31 23:59:59.999999', 'subsec'), date('0000-01-01', '-1 day')"},
  {"now once per statement", "", "SELECT count(DISTINCT julianday('now')), min(datetime('now') = current_timestamp), min(date() = current_date) FROM authors, posts"},
  {"date default", "CREATE TABLE stamped(id INTEGER PRIMARY KEY, created_at DEFAULT (datetime('now')), day DEFAULT CURRENT_DATE); INSERT INTO stamped(id) VALUES (1);", "SELECT length(created_at), day = date('now'), abs(julianday('now') - julianday(created_at)) < 0.01 FROM stamped"},
  {"date in check", "CREATE TABLE checked(x, CHECK (x < date('now')));", "INSERT INTO checked VALUES ('2020-01-01')"},

  # ANALYZE and sqlite_stat1
  {"analyze", "ANALYZE;", "SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY tbl, idx"},
  {"analyze table", "ANALYZE posts;", "SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY tbl, idx"},
  # VACUUM
  {"vacuum", "DELETE FROM posts; VACUUM;", "PRAGMA integrity_check"},
  {"vacuum pages", "DELETE FROM posts; VACUUM;", "SELECT * FROM pragma_freelist_count"},
  {"vacuum keeps rows", "VACUUM;", "SELECT * FROM authors ORDER BY id"},
]

struct Outcome
  getter code : Int32
  getter list_of_columns : Array(String)
  getter list_of_rows : Array(Array(String))
  getter message : String

  def initialize(@code, @list_of_columns, @list_of_rows, @message)
  end

  def same_as?(other : Outcome) : Bool
    code == other.code && list_of_columns == other.list_of_columns && list_of_rows == other.list_of_rows
  end

  def to_s(io : IO) : Nil
    io << "code=" << code
    io << " msg=" << message.inspect unless message.empty?
    io << " cols=" << list_of_columns.inspect << "\n"
    list_of_rows.each { |row| io << "    " << row.inspect << "\n" }
  end
end

def run_case(engine : ProbeEngine, path : String, extra : String, sql : String, eqp : Bool) : Outcome
  FileUtils.rm_rf(path)
  code, database = engine.open(path)
  raise "open failed (#{code})" unless code == ProbeEngine::OK_CODE
  begin
    setup_code = database.exec(SETUP + extra)
    return Outcome.new(setup_code, ["<setup>"], [] of Array(String), database.error_message) unless setup_code == ProbeEngine::OK_CODE
    code, statement = database.prepare(sql)
    return Outcome.new(code, [] of String, [] of Array(String), database.error_message) unless code == ProbeEngine::OK_CODE
    list_of_columns = (0...statement.column_count).map { |index| statement.column_name(index) }
    list_of_rows = [] of Array(String)
    step = ProbeEngine::ROW_CODE
    loop do
      step = statement.step
      break unless step == ProbeEngine::ROW_CODE
      list_of_rows << (0...statement.column_count).map do |column|
        case statement.column_type(column)
        when Grant::SQLite3::Type::INTEGER then "i:#{statement.column_int64(column)}"
        when Grant::SQLite3::Type::FLOAT   then "r:#{statement.column_double(column)}"
        when Grant::SQLite3::Type::NULL    then "null"
        when Grant::SQLite3::Type::BLOB    then "b:#{statement.column_blob(column).hexstring}"
        else                                    "t:#{statement.column_text(column)}"
        end
      end
    end
    message = step == ProbeEngine::DONE_CODE ? "" : database.error_message
    statement.finalize_statement
    list_of_rows = list_of_rows.map { |row| row.first(3) } if eqp
    Outcome.new(step, list_of_columns, list_of_rows, message)
  ensure
    database.close
  end
end

def backup_outcome(engine : ProbeEngine, directory : String) : String
  source_path = File.join(directory, "backup-src.db")
  target_path = File.join(directory, "backup-dst.db")
  FileUtils.rm_rf([source_path, target_path])
  _code, source = engine.open(source_path)
  source.exec(SETUP)
  _code, target = engine.open(target_path)
  result = begin
    source.backup_to(target).to_s
  rescue error
    "raised #{error.class}: #{error.message}"
  end
  source.close
  target.close
  check = IO::Memory.new
  Process.run("/usr/bin/sqlite3", [target_path, "PRAGMA integrity_check; SELECT count(*) FROM posts; SELECT first_name FROM authors ORDER BY id;"], output: check, error: check)
  "backup code=#{result} sqlite3: #{check.to_s.strip.gsub("\n", " | ")}"
end

directory = ARGV[0]? || abort("usage: g6probe REPORT_DIR")
Dir.mkdir_p(directory)
engines = {"grant" => ProbeEngine::GrantEngine.new.as(ProbeEngine), "c" => ProbeEngine::LibSQLite3Engine.new.as(ProbeEngine)}
report = File.open(File.join(directory, "g6_probe.txt"), "w")
differences = 0
list_of_cases = CASES.map { |name, extra, sql| {name, extra, sql, false} }
list_of_cases << {"explain query plan", "", "EXPLAIN QUERY PLAN SELECT * FROM posts WHERE author_id = 1 ORDER BY score DESC", true}
list_of_cases << {"explain query plan join", "", "EXPLAIN QUERY PLAN SELECT a.first_name, p.title FROM authors a JOIN posts p ON p.author_id = a.id", true}
list_of_cases.each do |name, extra, sql, eqp|
  outcomes = engines.map do |label, engine|
    outcome = begin
      run_case(engine, File.join(directory, "#{label}.db"), extra, sql, eqp)
    rescue error
      Outcome.new(-1, ["<raised>"], [[error.class.name, error.message.to_s]], "")
    end
    {label, outcome}
  end.to_h
  same = outcomes["grant"].same_as?(outcomes["c"])
  differences += 1 unless same
  report << (same ? "SAME " : "DIFF ") << name << "\n  sql: " << sql << "\n"
  report << "  grant: " << outcomes["grant"]
  report << "  c:     " << outcomes["c"] unless same
end
engines.each { |label, engine| report << label << " " << backup_outcome(engine, directory) << "\n" }
report << "cases " << list_of_cases.size << ", differences " << differences << "\n"
report.close
puts File.read(File.join(directory, "g6_probe.txt")).lines.select { |line| line.starts_with?("DIFF") || line.starts_with?("cases") || line.includes?("backup") }.join("\n")
