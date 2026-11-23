# Builds SQLite database fixtures with the sqlite3 command-line tool and, for
# each one, the rows and index entries C SQLite returns, in the canonical
# typed JSON-lines form Grant::SQLiteEngine::Dump writes. The engine's specs
# compare the two.
#
#   /usr/bin/ruby generate.rb standard OUT_DIR
#   /usr/bin/ruby generate.rb random OUT_DIR --count 1000 --seed 12345
#   /usr/bin/ruby generate.rb corpus OUT_DIR --corpus ../corpus/grant_sql_corpus.txt
#
# Each run writes OUT_DIR/manifest.json naming every fixture, its sha256, its
# -wal file's sha256 (when it has one) and the exact sqlite3 version. The
# expected dump is taken from a copy of each fixture, so a WAL left in place
# is never checkpointed by the sqlite3 tool.
require "json"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"

SQLITE3 = ENV.fetch("SQLITE3", "sqlite3")

def sqlite3(database, sql, *flags)
  output, error, status = Open3.capture3(SQLITE3, *flags, database, stdin_data: sql)
  raise "sqlite3 #{database} failed: #{error}\n#{sql[0, 2000]}" unless status.success? && error.empty?
  output
end

def quote_name(name)
  "\"#{name.gsub('"', '""')}\""
end

def quote_text(text)
  "'#{text.gsub("'", "''")}'"
end

# One value as the canonical JSON the engine's dump writes.
def canonical_expression(expression)
  "CASE typeof(#{expression}) " \
    "WHEN 'null' THEN 'null' " \
    "WHEN 'integer' THEN CAST(#{expression} AS TEXT) " \
    "WHEN 'real' THEN '{\"real\":\"0x' || hex(ieee754_to_blob(#{expression})) || '\"}' " \
    "WHEN 'text' THEN json_quote(#{expression}) " \
    "ELSE '{\"blob\":\"' || hex(#{expression}) || '\"}' END"
end

def row_expression(list_of_expressions)
  return "'[]'" if list_of_expressions.empty?
  "'[' || " + list_of_expressions.map { |expression| canonical_expression(expression) }.join(" || ',' || ") + " || ']'"
end

METADATA_SQL = <<~SQL
  SELECT 'index' AS kind, s.name AS object, s.tbl_name AS tbl, coalesce(s.sql, '') AS sql,
         x.seqno AS seq, x.cid AS cid, x.name AS col, x."desc" AS dsc, x.coll AS coll, x.key AS key
    FROM sqlite_schema AS s JOIN pragma_index_xinfo(s.name) AS x
   WHERE s.type = 'index' AND s.rootpage > 0
  UNION ALL
  SELECT 'table', s.name, s.tbl_name, coalesce(s.sql, ''), x.cid, x.cid, x.name, 0, '', x.hidden
    FROM sqlite_schema AS s JOIN pragma_table_xinfo(s.name) AS x
   WHERE s.type = 'table' AND s.rootpage > 0
  UNION ALL
  SELECT 'pk', s.name, s.name, '', x.seqno, x.cid, x.name, x."desc", x.coll, x.key
    FROM sqlite_schema AS s JOIN pragma_index_list(s.name) AS l JOIN pragma_index_xinfo(l.name) AS x
   WHERE s.type = 'table' AND l.origin = 'pk' AND x.key = 1;
SQL

# The SQL that prints every table and index of a database in the canonical
# form, objects in name (byte) order.
def expected_dump_sql(database)
  output = sqlite3(database, METADATA_SQL, "-json")
  rows = output.strip.empty? ? [] : JSON.parse(output)
  objects = rows.group_by { |row| [row["kind"], row["object"]] }
  tables = objects.select { |(kind, _), _| kind == "table" }
  indexes = objects.select { |(kind, _), _| kind == "index" }
  primary_keys = objects.select { |(kind, _), _| kind == "pk" }.to_h { |(_, name), list| [name, list.sort_by { |row| row["seq"] }] }

  statements = []
  (tables.keys + indexes.keys).sort_by { |(_, name)| name.b }.each do |kind, name|
    list = objects[[kind, name]].sort_by { |row| row["seq"] }
    if kind == "table"
      sql = list.first["sql"]
      columns = list.map { |row| quote_name(row["col"]) }
      without_rowid = sql.match?(/WITHOUT\s+ROWID/i)
      order = if without_rowid
                primary_keys.fetch(name).map { |row| order_term(quote_name(row["col"]), row) }.join(", ")
              else
                "rowid"
              end
      leading = without_rowid ? "'null'" : canonical_expression("rowid")
      line = "'[' || #{leading}" + columns.map { |column| " || ',' || " + canonical_expression(column) }.join + " || ']'"
      statements << "SELECT #{quote_text("# table #{name}")};"
      statements << "SELECT #{line} FROM #{quote_name(name)} ORDER BY #{order};"
    else
      table = list.first["tbl"]
      sql = list.first["sql"]
      key_terms = index_key_terms(sql)
      expressions = list.map do |row|
        case row["cid"]
        when -1 then "rowid"
        when -2 then key_terms.fetch(row["seq"]) { raise "cannot read expression #{row['seq']} of index #{name}" }
        else quote_name(row["col"])
        end
      end
      order = list.zip(expressions).map { |row, expression| order_term(expression, row) }.join(", ")
      where = sql[/\)\s*WHERE\s+(.*)\z/im, 1]
      statements << "SELECT #{quote_text("# index #{name}")};"
      statements << "SELECT #{row_expression(expressions)} FROM #{quote_name(table)}#{where ? " WHERE #{where.sub(/;\s*\z/, '')}" : ''} ORDER BY #{order};"
    end
  end
  statements.join("\n")
end

# The key terms of a CREATE INDEX, each without its COLLATE and ASC/DESC,
# so an expression index's values can be selected from its table.
def index_key_terms(sql)
  start = sql.index("(")
  return [] unless start
  terms = []
  depth = 0
  current = +""
  quote = nil
  sql[(start + 1)..].each_char do |char|
    if quote
      quote = nil if char == quote
      current << char
      next
    end
    case char
    when "'", '"', "`" then quote = char
    when "(" then depth += 1
    when ")"
      if depth.zero?
        terms << current
        break
      end
      depth -= 1
    when ","
      if depth.zero?
        terms << current
        current = +""
        next
      end
    end
    current << char
  end
  terms.map { |term| term.strip.sub(/\s+(ASC|DESC)\z/i, "").sub(/\s+COLLATE\s+\S+\z/i, "").strip }
end

def order_term(expression, row)
  collation = row["coll"].to_s.empty? ? "" : " COLLATE #{row["coll"]}"
  "#{expression}#{collation}#{row["dsc"] == 1 ? ' DESC' : ''}"
end

# Writes NAME.expected beside the fixture, read from a scratch copy.
def write_expected(out_dir, name)
  database = File.join(out_dir, "#{name}.db")
  Dir.mktmpdir("grant-sqlite-expected") do |scratch|
    copy = File.join(scratch, "copy.db")
    FileUtils.cp(database, copy)
    FileUtils.cp("#{database}-wal", "#{copy}-wal") if File.exist?("#{database}-wal")
    sql = expected_dump_sql(copy)
    File.write(File.join(out_dir, "#{name}.expected"), sql.empty? ? "" : sqlite3(copy, sql, "-list", "-bail"))
  end
end

def manifest_entry(out_dir, name, kind, extra = {})
  database = File.join(out_dir, "#{name}.db")
  entry = { "name" => name, "kind" => kind, "sha256" => Digest::SHA256.file(database).hexdigest }
  entry["wal_sha256"] = Digest::SHA256.file("#{database}-wal").hexdigest if File.exist?("#{database}-wal")
  entry.merge(extra)
end

def build(out_dir, name, sql)
  database = File.join(out_dir, "#{name}.db")
  FileUtils.rm_f([database, "#{database}-wal", "#{database}-shm", "#{database}-journal"])
  sqlite3(database, sql, "-bail")
  database
end

# --- Standard fixtures ---------------------------------------------------

SERIAL_TYPE_ROWS = <<~SQL
  CREATE TABLE serial_types(label TEXT, v);
  INSERT INTO serial_types VALUES
    ('null', NULL), ('zero', 0), ('one', 1), ('int8', 127), ('int8 negative', -128),
    ('int16', 32767), ('int16 negative', -32768), ('int24', 8388607), ('int24 negative', -8388608),
    ('int32', 2147483647), ('int32 negative', -2147483648), ('int48', 140737488355327),
    ('int48 negative', -140737488355328), ('int64', 9223372036854775807),
    ('int64 min', -9223372036854775807 - 1), ('real', 3.141592653589793), ('real whole', 2.0),
    ('real tiny', 5e-324), ('real huge', 1.7976931348623157e308), ('real negative zero', -0.0),
    ('real infinity', 9e999), ('real negative infinity', -9e999),
    ('text empty', ''), ('text', 'hello'), ('text unicode', 'é€😀 日本語'),
    ('text quote', 'it''s "quoted" \\ back'), ('text control', char(1, 9, 10, 13, 31, 127)),
    ('blob empty', x''), ('blob', x'00ff10'), ('blob ascii', CAST('abc' AS BLOB));
SQL

AFFINITY_TABLE = <<~SQL
  CREATE TABLE affinities(i INTEGER, r REAL, d DOUBLE PRECISION, f FLOAT, n NUMERIC, t TEXT, b BLOB, v VARCHAR(10), none_typed);
  INSERT INTO affinities VALUES (1, 1, 1, 1, 1, 1, 1, 1, 1), ('2', '2', '2.0', '2.5', '2.0', 2, 2, 2.5, '2'),
    (3.0, 3.0, 3.5, 3e0, '3e2', 3.0, 3.0, 3.0, 3.0), (NULL, -0.0, 1e20, 1e300, '1e400', x'01', 'b', 'v', x'02'),
    ('abc', 'abc', 'abc', 'abc', 'abc', 'abc', 'abc', 'abc', 'abc'), (9223372036854775807, 9223372036854775807, 4.5e15, 9.0e15, 12345678901234567890, 1, 1, 1, 1);
  CREATE INDEX affinities_by_real ON affinities(r);
  CREATE INDEX affinities_by_numeric_and_text ON affinities(n, t);
SQL

def rows_sql(table, count, wide: false)
  payload = wide ? "printf('%.*c', 300 + (value % 400), 'w')" : "'row ' || value"
  <<~SQL
    WITH RECURSIVE numbers(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < #{count})
    INSERT INTO #{table}(label, amount, score, payload)
      SELECT 'label ' || (value * 7919 % #{count + 1}), value * 3 - #{count}, value / 7.0, #{payload} FROM numbers;
  SQL
end

def standard_table_sql(table, count, wide: false)
  <<~SQL
    CREATE TABLE #{table}(id INTEGER PRIMARY KEY, label TEXT, amount INTEGER, score REAL, payload);
    #{rows_sql(table, count, wide: wide)}
    CREATE INDEX #{table}_by_label ON #{table}(label);
    CREATE INDEX #{table}_by_amount_desc ON #{table}(amount DESC);
    CREATE INDEX #{table}_by_score ON #{table}(score);
    CREATE INDEX #{table}_by_label_and_amount ON #{table}(label COLLATE NOCASE, amount);
  SQL
end

def standard_fixtures
  fixtures = {}
  [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536].each do |page_size|
    fixtures["page_size_#{page_size}"] = "PRAGMA page_size=#{page_size};\n#{standard_table_sql('items', 600, wide: true)}\n#{SERIAL_TYPE_ROWS}"
  end
  { "none" => 0, "full" => 1, "incremental" => 2 }.each do |mode, code|
    fixtures["auto_vacuum_#{mode}"] = <<~SQL
      PRAGMA page_size=1024; PRAGMA auto_vacuum=#{code};
      #{standard_table_sql('items', 2000, wide: true)}
      DELETE FROM items WHERE id % 3 = 0;
      #{code == 2 ? 'PRAGMA incremental_vacuum(5);' : ''}
    SQL
  end
  { "utf8" => "UTF-8", "utf16le" => "UTF-16le", "utf16be" => "UTF-16be" }.each do |label, encoding|
    fixtures["encoding_#{label}"] = <<~SQL
      PRAGMA encoding='#{encoding}';
      #{SERIAL_TYPE_ROWS}
      CREATE TABLE words(word TEXT, note TEXT);
      INSERT INTO words VALUES ('café', 'é'), ('Ωmega', 'Ω'), ('😀 face', '😀'), ('plain', NULL), ('', ''), (printf('%.*c', 3000, 'ü'), 'long');
      CREATE INDEX words_by_word ON words(word);
      CREATE INDEX words_by_note_nocase ON words(note COLLATE NOCASE DESC);
    SQL
  end
  fixtures["serial_types"] = "#{SERIAL_TYPE_ROWS}\nCREATE INDEX serial_types_by_v ON serial_types(v);"
  fixtures["affinities"] = AFFINITY_TABLE
  fixtures["overflow"] = <<~SQL
    PRAGMA page_size=1024;
    CREATE TABLE blobs(id INTEGER PRIMARY KEY, label TEXT, body BLOB);
    INSERT INTO blobs VALUES (1, 'fits', randomblob(100)), (2, 'one overflow page', randomblob(1500)),
      (3, 'two overflow pages', randomblob(2500)), (4, 'hundred overflow pages', randomblob(102000)),
      (5, 'text overflow', printf('%.*c', 5000, 't')), (6, 'exactly max local', randomblob(989)),
      (7, 'one past max local', randomblob(990));
    CREATE TABLE keyed(k TEXT PRIMARY KEY, v);
    INSERT INTO keyed SELECT printf('%.*c', 600 + value, 'k') || value, value FROM (WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 300) SELECT value FROM n);
    CREATE INDEX blobs_by_body ON blobs(body);
  SQL
  [1, 1000, 200_000].each do |count|
    fixtures["rows_#{count}"] = standard_table_sql("items", count)
  end
  fixtures["without_rowid"] = <<~SQL
    CREATE TABLE pairs(region TEXT, code INTEGER, label TEXT, weight REAL, PRIMARY KEY(region, code DESC)) WITHOUT ROWID;
    WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 3000)
    INSERT INTO pairs SELECT 'region ' || (value % 17), value, printf('%.*c', value % 900, 'p'), value / 3.0 FROM n;
    CREATE INDEX pairs_by_label ON pairs(label);
    CREATE INDEX pairs_by_weight ON pairs(weight, code);
    CREATE TABLE settings(setting_key TEXT PRIMARY KEY COLLATE NOCASE, setting_value) WITHOUT ROWID;
    INSERT INTO settings VALUES ('b', 1), ('A', 2), ('c', x'00'), ('D', NULL);
    CREATE TABLE middle_key(a, b TEXT, c INTEGER, PRIMARY KEY(c, b)) WITHOUT ROWID;
    INSERT INTO middle_key VALUES (1, 'x', 3), (2, 'y', 1), (3.5, 'z', 2), (NULL, 'w', 2);
  SQL
  fixtures["freelist"] = <<~SQL
    PRAGMA page_size=1024;
    #{standard_table_sql('items', 5000, wide: true)}
    DELETE FROM items WHERE id % 5 != 0;
    CREATE TABLE dropped(x); INSERT INTO dropped SELECT randomblob(800) FROM items; DROP TABLE dropped;
  SQL
  fixtures["schema_shapes"] = <<~SQL
    CREATE TABLE "quoted ""table"""("weird ""column""" INTEGER PRIMARY KEY, [bracket col] TEXT, `tick col` REAL);
    INSERT INTO "quoted ""table""" VALUES (5, 'a', 1), (7, 'b', 2.5);
    CREATE TABLE big_key(id BIGINT PRIMARY KEY, label TEXT);
    INSERT INTO big_key VALUES (10, 'ten'), (3, 'three');
    CREATE TABLE desc_key(id INTEGER PRIMARY KEY DESC, label TEXT);
    INSERT INTO desc_key VALUES (4, 'four'), (2, 'two');
    CREATE TABLE table_key(id INTEGER, label TEXT, PRIMARY KEY(id DESC));
    INSERT INTO table_key VALUES (8, 'eight'), (1, 'one');
    CREATE TABLE constraints(
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      email VARCHAR(255) NOT NULL UNIQUE ON CONFLICT ABORT,
      parent_id INTEGER REFERENCES constraints(id) ON DELETE SET NULL ON UPDATE NO ACTION DEFERRABLE INITIALLY DEFERRED,
      amount DECIMAL(10, 2) DEFAULT 0.0 CHECK (amount >= 0),
      flag BOOLEAN DEFAULT FALSE,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      code CHAR(3) COLLATE NOCASE DEFAULT 'abc',
      doubled INTEGER GENERATED ALWAYS AS (amount * 2) STORED,
      CONSTRAINT one_email UNIQUE (email, code),
      FOREIGN KEY (parent_id) REFERENCES constraints(id)
    );
    INSERT INTO constraints(email, parent_id, amount, flag, created_at) VALUES ('a@x', NULL, 1.5, TRUE, '2026-11-22 10:00:00.000000'), ('b@x', 1, 2, FALSE, NULL);
    CREATE TABLE later(id INTEGER PRIMARY KEY, label TEXT);
    INSERT INTO later VALUES (1, 'before'), (2, 'before too');
    ALTER TABLE later ADD COLUMN added_int INTEGER DEFAULT 42;
    ALTER TABLE later ADD COLUMN added_text TEXT DEFAULT 'fresh';
    ALTER TABLE later ADD COLUMN added_real REAL DEFAULT -1;
    ALTER TABLE later ADD COLUMN added_null BLOB;
    ALTER TABLE later ADD COLUMN added_numeric NUMERIC DEFAULT '7.0';
    ALTER TABLE later ADD COLUMN added_blob BLOB DEFAULT x'cafe';
    INSERT INTO later(label) VALUES ('after');
    CREATE TABLE sequence_user(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
    INSERT INTO sequence_user(v) VALUES (1), (2);
    CREATE VIEW view_of_later AS SELECT * FROM later;
    CREATE TRIGGER later_touch AFTER INSERT ON later BEGIN SELECT 1; END;
    CREATE UNIQUE INDEX later_by_label ON later(label);
    CREATE INDEX later_partial ON later(added_int) WHERE label IS NOT NULL;
    CREATE TABLE unique_pairs(a REAL, b TEXT, UNIQUE(a, b), UNIQUE(b));
    INSERT INTO unique_pairs VALUES (1, 'x'), (2.5, 'y'), (3, 'z');
    ANALYZE;
  SQL
  fixtures
end

def write_wal_fixtures(out_dir, manifest)
  # Rows 1-50 reach the main file through a checkpoint; rows 51-80 exist
  # only in the -wal file, which the closing connection leaves in place.
  name = "wal_committed"
  build(out_dir, name, <<~SQL)
    PRAGMA journal_mode=wal;
    PRAGMA wal_autocheckpoint=0;
    CREATE TABLE events(id INTEGER PRIMARY KEY, label TEXT, body BLOB);
    WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 50)
    INSERT INTO events SELECT value, 'checkpointed ' || value, randomblob(value * 20) FROM n;
    PRAGMA wal_checkpoint(TRUNCATE);
    .dbconfig no_ckpt_on_close on
    WITH RECURSIVE n(value) AS (SELECT 51 UNION ALL SELECT value + 1 FROM n WHERE value < 80)
    INSERT INTO events SELECT value, 'only in the wal ' || value, randomblob(value * 20) FROM n;
    UPDATE events SET label = 'updated in the wal' WHERE id = 3;
    DELETE FROM events WHERE id = 4;
    CREATE INDEX events_by_label ON events(label);
  SQL
  write_expected(out_dir, name)
  manifest << manifest_entry(out_dir, name, "wal", "wal_only_label_prefix" => "only in the wal")

  # A later WAL generation overwrites the start of the log: frames of the
  # previous generation stay behind it with the old salts and must be ignored.
  name = "wal_restarted"
  build(out_dir, name, <<~SQL)
    PRAGMA page_size=1024;
    PRAGMA journal_mode=wal;
    PRAGMA wal_autocheckpoint=0;
    CREATE TABLE events(id INTEGER PRIMARY KEY, label TEXT, body BLOB);
    WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 400)
    INSERT INTO events SELECT value, 'first generation ' || value, randomblob(200) FROM n;
    PRAGMA wal_checkpoint(PASSIVE);
    .dbconfig no_ckpt_on_close on
    INSERT INTO events VALUES (1000, 'second generation', x'00');
  SQL
  write_expected(out_dir, name)
  manifest << manifest_entry(out_dir, name, "wal")

  # A torn write: garbage appended after the last committed frame.
  name = "wal_torn_tail"
  FileUtils.cp(File.join(out_dir, "wal_committed.db"), File.join(out_dir, "#{name}.db"))
  wal = File.binread(File.join(out_dir, "wal_committed.db-wal"))
  frame_size = 24 + wal[8, 4].unpack1("N")
  torn = wal + wal[32, frame_size].dup.tap { |frame| frame.setbyte(30, frame.getbyte(30) ^ 0xff) } + "\x00" * 100
  File.binwrite(File.join(out_dir, "#{name}.db-wal"), torn)
  write_expected(out_dir, name)
  manifest << manifest_entry(out_dir, name, "wal")
end

def run_standard(out_dir)
  manifest = []
  standard_fixtures.each do |name, sql|
    build(out_dir, name, sql)
    write_expected(out_dir, name)
    manifest << manifest_entry(out_dir, name, "standard")
  end
  write_wal_fixtures(out_dir, manifest)
  manifest
end

# --- The Grant statement corpus ------------------------------------------

# Every CREATE TABLE and CREATE INDEX Grant's spec suite issued, run in one
# database (later definitions of a name replace earlier ones), with rows of
# every storage class inserted into each table.
def run_corpus(out_dir, corpus_path, seed)
  random = Random.new(seed)
  creates = File.readlines(corpus_path, chomp: true).grep(/\A\s*CREATE\s+(TABLE|UNIQUE INDEX|INDEX)\b/i).reject { |sql| sql.include?("?") }
  database = File.join(out_dir, "grant_corpus_schema.db")
  FileUtils.rm_f(database)
  accepted = 0
  creates.each do |sql|
    _output, _error, status = Open3.capture3(SQLITE3, database, stdin_data: "#{sql.sub(/;?\s*\z/, '')};")
    accepted += 1 if status.success?
  end
  tables = JSON.parse(sqlite3(database, "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%';", "-json").then { |out| out.strip.empty? ? "[]" : out })
  inserts = +"PRAGMA foreign_keys=OFF;\nBEGIN;\n"
  tables.each do |row|
    table = row["name"]
    columns = JSON.parse(sqlite3(database, "SELECT name, type, pk FROM pragma_table_xinfo(#{quote_text(table)}) WHERE hidden = 0;", "-json"))
    next if columns.empty?
    names = columns.map { |column| quote_name(column["name"]) }.join(", ")
    5.times do
      values = columns.map do |column|
        rowid_alias = column["pk"].to_i > 0 && column["type"].to_s.casecmp?("INTEGER")
        rowid_alias ? random.rand(1..1_000_000).to_s : random_value(random)
      end
      inserts << "INSERT OR IGNORE INTO #{quote_name(table)}(#{names}) VALUES (#{values.join(', ')});\n"
    end
  end
  inserts << "COMMIT;\n"
  # Some rows break a table's CHECK or type rules; sqlite3 reports them and
  # goes on, and the fixture keeps every row it accepted.
  Open3.capture3(SQLITE3, database, stdin_data: inserts)
  rows = sqlite3(database, tables.map { |row| "SELECT count(*) FROM #{quote_name(row['name'])};" }.join("\n")).lines.sum(&:to_i)
  write_expected(out_dir, "grant_corpus_schema")
  [manifest_entry(out_dir, "grant_corpus_schema", "corpus", "create_statements" => creates.size, "create_statements_accepted" => accepted, "tables" => tables.size, "rows" => rows)]
end

# --- Random databases ----------------------------------------------------

TYPES = ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "VARCHAR(20)", "BOOLEAN", "", "DOUBLE", "BIGINT", "DATETIME", "FLOAT"].freeze

def random_text(random)
  length = random.rand(100) < 3 ? random.rand(1500..20_000) : random.rand(0..40)
  Array.new(length) do
    case random.rand(10)
    when 0 then [random.rand(0x80..0x7ff)].pack("U")
    when 1 then [random.rand(0x800..0xd7ff)].pack("U")
    when 2 then [random.rand(0x10000..0x10ffff)].pack("U")
    else (random.rand(32..126)).chr
    end
  end.join
end

def random_value(random)
  case random.rand(12)
  when 0 then "NULL"
  when 1 then random.rand(-200..200).to_s
  when 2 then random.rand(-(2**62)..(2**62)).to_s
  when 3 then ["9223372036854775807", "(-9223372036854775807 - 1)", "0", "1", "-1"].sample(random: random)
  when 4 then (random.rand * 10**random.rand(-10..20) * (random.rand(2).zero? ? 1 : -1)).to_s
  when 5 then "#{random.rand(-1000..1000)}.0"
  when 6 then ["9e999", "-9e999", "5e-324", "-0.0", "1.7976931348623157e308"].sample(random: random)
  when 7, 8 then quote_text(random_text(random))
  when 9 then quote_text(random.rand(-1000..1000).to_s)
  else
    size = random.rand(100) < 3 ? random.rand(1500..30_000) : random.rand(0..40)
    "x'#{random.bytes(size).unpack1('H*')}'"
  end
end

def random_database_sql(random)
  sql = +""
  sql << "PRAGMA page_size=#{[512, 1024, 2048, 4096, 8192, 16384, 32768, 65536].sample(random: random)};\n"
  sql << "PRAGMA encoding='#{['UTF-8', 'UTF-16le', 'UTF-16be'].sample(random: random)}';\n"
  sql << "PRAGMA auto_vacuum=#{random.rand(3)};\n"
  wal = random.rand(4).zero?
  sql << "PRAGMA journal_mode=wal;\nPRAGMA wal_autocheckpoint=0;\n" if wal
  tables = []
  random.rand(1..4).times do |table_number|
    table = "t#{table_number}"
    column_count = random.rand(1..8)
    columns = Array.new(column_count) { |index| ["c#{index}", TYPES.sample(random: random)] }
    shape = random.rand(4)
    definitions = columns.map { |column_name, type| "#{column_name} #{type}".strip }
    without_rowid = false
    case shape
    when 1
      definitions[0] = "c0 INTEGER PRIMARY KEY"
      columns[0][1] = "INTEGER"
    when 2
      key = columns.first(random.rand(1..[2, column_count].min)).map(&:first)
      definitions << "PRIMARY KEY(#{key.map { |key_column| random.rand(3).zero? ? "#{key_column} DESC" : key_column }.join(', ')})"
      # A one-column table key on an INTEGER column aliases the rowid too.
      shape = 1 if key.size == 1 && columns[0][1] == "INTEGER"
    when 3
      key = columns.first(random.rand(1..[2, column_count].min)).map(&:first)
      definitions << "PRIMARY KEY(#{key.join(', ')})"
      without_rowid = true
    end
    sql << "CREATE TABLE #{table}(#{definitions.join(', ')})#{without_rowid ? ' WITHOUT ROWID' : ''};\n"
    random.rand(0..2).times do |index_number|
      picked = columns.map(&:first).sample(random.rand(1..[3, column_count].min), random: random)
      terms = picked.map { |column| "#{column}#{random.rand(4).zero? ? ' COLLATE NOCASE' : ''}#{random.rand(3).zero? ? ' DESC' : ''}" }
      unique = random.rand(5).zero? ? "UNIQUE " : ""
      sql << "CREATE #{unique}INDEX #{table}_i#{index_number} ON #{table}(#{terms.join(', ')});\n"
    end
    tables << [table, columns, shape]
  end
  checkpointed = false
  random.rand(1..3).times do |batch|
    tables.each do |table, columns, shape|
      random.rand(0..150).times do
        values = columns.map.with_index do |(_column_name, _type), index|
          if shape == 1 && index.zero?
            random.rand(2).zero? ? "NULL" : random.rand(-(2**62)..(2**62)).to_s
          else
            random_value(random)
          end
        end
        sql << "INSERT OR IGNORE INTO #{table} VALUES (#{values.join(', ')});\n"
      end
      sql << "DELETE FROM #{table} WHERE random() % 4 = 0;\n" if random.rand(2).zero?
      sql << "UPDATE OR IGNORE #{table} SET #{columns.last.first} = #{random_value(random)} WHERE random() % 3 = 0;\n" if random.rand(3).zero? && shape != 3 && !(shape == 1 && columns.size == 1)
      if batch.zero? && random.rand(4).zero?
        added = "a#{random.rand(1000)}"
        sql << "ALTER TABLE #{table} ADD COLUMN #{added} #{TYPES.sample(random: random)} DEFAULT #{random_value(random).sub(/\A\(.*\)\z/, '0')};\n"
        columns << [added, ""]
      end
    end
    if wal && !checkpointed && random.rand(2).zero?
      sql << "PRAGMA wal_checkpoint(TRUNCATE);\n"
      checkpointed = true
    end
  end
  sql << "PRAGMA incremental_vacuum(#{random.rand(1..10)});\n" if random.rand(3).zero?
  sql << ".dbconfig no_ckpt_on_close on\n" if wal
  sql
end

def run_random(out_dir, count, seed)
  manifest = []
  count.times do |number|
    database_seed = seed + number
    random = Random.new(database_seed)
    name = format("random_%05d", number)
    build(out_dir, name, random_database_sql(random))
    write_expected(out_dir, name)
    manifest << manifest_entry(out_dir, name, "random", "seed" => database_seed)
  end
  manifest
end

mode, out_dir = ARGV[0], ARGV[1]
abort "usage: generate.rb standard|random|corpus OUT_DIR [--count N] [--seed S] [--corpus PATH]" unless %w[standard random corpus].include?(mode) && out_dir
options = ARGV[2..].each_slice(2).to_h
FileUtils.mkdir_p(out_dir)
seed = Integer(options.fetch("--seed", (Time.now.to_i % 1_000_000).to_s))
entries = case mode
          when "standard" then run_standard(out_dir)
          when "random" then run_random(out_dir, Integer(options.fetch("--count", "50")), seed)
          else run_corpus(out_dir, options.fetch("--corpus"), seed)
          end
version = sqlite3(":memory:", "SELECT sqlite_version() || ' ' || sqlite_source_id();").strip
File.write(File.join(out_dir, "manifest.json"), JSON.pretty_generate("mode" => mode, "seed" => seed, "sqlite3_version" => version, "fixtures" => entries))
puts "#{mode}: #{entries.size} fixtures, seed #{seed}, sqlite3 #{version}"
