# Random write sequences for Grant::SQLiteEngine's writer, and the checks
# C SQLite makes of the files the engine writes.
#
#   /usr/bin/ruby operations.rb sequences OUT_DIR --count 100 --seed 1 [--start 0] [--size regular|small] [--wal 1]
#   /usr/bin/ruby operations.rb verify OUT_DIR SUFFIX
#   /usr/bin/ruby operations.rb corpus OUT_DIR --corpus ../corpus/grant_sql_corpus.txt --seed 1
#
# "sequences" writes, for each sequence, seq_NNNNN.json (the operations as
# typed values, which the engine applies through its write API) and builds
# seq_NNNNN.c.db by running the same operations as SQL through the sqlite3
# tool, recording the statements sqlite3 rejected in seq_NNNNN.c.errors.
#
# "verify" runs, for every OUT_DIR/*.SUFFIX.db, PRAGMA integrity_check
# (NAME.integrity), the canonical dump of every table and index
# (NAME.expected, the form Grant::SQLiteEngine::Dump writes) and the
# schema rows without root pages (NAME.schema). Opening a file with a hot
# journal rolls it back first, as C SQLite does.
#
# "corpus" builds every CREATE TABLE and CREATE INDEX of the statement
# corpus with sqlite3 and 5 rows per table, and writes corpus.json: the
# statements and the rows sqlite3 kept (rowid and typed values), for the
# engine to apply.
require_relative "generate"

SCHEMA_SQL = "SELECT json_array(type, name, tbl_name, sql) FROM sqlite_schema ORDER BY name;"

# --- Typed values ---------------------------------------------------------

def typed_integer(value)
  sql = value == -(2**63) ? "(-9223372036854775807 - 1)" : value.to_s
  [{ "i" => value.to_s }, sql]
end

def typed_real(value)
  bits = [value].pack("G").unpack1("H*").upcase
  [{ "r" => bits }, "ieee754_from_blob(x'#{bits}')"]
end

def typed_text(text)
  [{ "t" => text }, quote_text(text)]
end

def typed_blob(bytes)
  hex = bytes.unpack1("H*")
  [{ "b" => hex }, "x'#{hex}'"]
end

NULL_VALUE = [nil, "NULL"].freeze

def grant_time_text(random)
  format("2026-%02d-%02d %02d:%02d:%02d.%06d", random.rand(1..12), random.rand(1..28), random.rand(24), random.rand(60), random.rand(60), random.rand(1_000_000))
end

def typed_value(random)
  case random.rand(14)
  when 0 then NULL_VALUE
  when 1, 2 then typed_integer(random.rand(-200..200))
  when 3 then typed_integer(random.rand(-(2**62)..(2**62)))
  when 4 then typed_integer([2**63 - 1, -(2**63), 0, 1, -1, 2**47, -(2**47) - 1].sample(random: random))
  when 5 then typed_real(random.rand * 10**random.rand(-10..20) * (random.rand(2).zero? ? 1 : -1))
  when 6 then typed_real(random.rand(-1000..1000).to_f)
  when 7 then typed_real([Float::INFINITY, -Float::INFINITY, 5e-324, -0.0, 1.7976931348623157e308, 2.0**60].sample(random: random))
  when 8, 9 then typed_text(random_text(random))
  when 10 then typed_text([" 12 ", "1.5", "+7", "1e3", "-0", "007", "12abc", "", "Abc", "abc ", "ABC"].sample(random: random))
  when 11 then typed_text(grant_time_text(random))
  else
    size = random.rand(100) < 3 ? random.rand(1500..30_000) : random.rand(0..40)
    typed_blob(random.bytes(size))
  end
end

def key_value(random)
  case random.rand(4)
  when 0 then typed_integer(random.rand(1..60))
  when 1 then typed_text(["a", "b", "A", "B", "c ", "c", "10", "x" * random.rand(1..3)].sample(random: random))
  else typed_value(random).first.nil? ? typed_integer(random.rand(1..60)) : typed_value(random)
  end
end

# --- Schemas --------------------------------------------------------------

PLAIN_TYPES = ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "VARCHAR(20)", "BOOLEAN", "", "DOUBLE", "BIGINT",
               "DATETIME", "FLOAT", "TEXT COLLATE NOCASE", "VARCHAR(20) COLLATE RTRIM"].freeze
STRICT_TYPES = ["INT", "INTEGER", "REAL", "TEXT", "BLOB", "ANY", "TEXT COLLATE NOCASE"].freeze

def random_table(random, name)
  strict = random.rand(7).zero?
  column_count = random.rand(1..6)
  columns = Array.new(column_count) do |index|
    type = (strict ? STRICT_TYPES : PLAIN_TYPES).sample(random: random)
    constraints = +""
    constraints << " NOT NULL" if random.rand(10).zero?
    constraints << " UNIQUE" if random.rand(15).zero?
    { "name" => "c#{index}", "type" => type, "definition" => "c#{index} #{type}#{constraints}".strip, "not_null" => !constraints.empty? && constraints.include?("NOT NULL") }
  end
  shape = random.rand(5)
  table_constraints = []
  table = { "name" => name, "columns" => columns, "alias" => nil, "without_rowid" => false, "key" => [], "rowids" => [], "keys" => [], "next_rowid" => 1, "autoincrement" => false }
  case shape
  when 1
    columns[0]["type"] = "INTEGER"
    autoincrement = random.rand(3).zero?
    columns[0]["definition"] = "c0 INTEGER PRIMARY KEY#{autoincrement ? ' AUTOINCREMENT' : ''}"
    columns[0]["not_null"] = false
    table["alias"] = 0
    table["autoincrement"] = autoincrement
  when 2
    key = columns.first(random.rand(1..[2, column_count].min)).map { |column| column["name"] }
    table_constraints << "PRIMARY KEY(#{key.map { |column| random.rand(3).zero? ? "#{column} DESC" : column }.join(', ')})"
    if key.size == 1 && columns[0]["type"] == "INTEGER"
      table["alias"] = 0
    end
  when 3
    key = columns.first(random.rand(1..[2, column_count].min)).map { |column| column["name"] }
    table_constraints << "PRIMARY KEY(#{key.map { |column| random.rand(4).zero? ? "#{column} DESC" : column }.join(', ')})"
    table["without_rowid"] = true
    table["key"] = key.map { |column| columns.index { |candidate| candidate["name"] == column } }
  end
  if column_count >= 2 && random.rand(6).zero?
    picked = columns.map { |column| column["name"] }.sample(2, random: random)
    table_constraints << "UNIQUE(#{picked.join(', ')})"
  end
  options = []
  options << "WITHOUT ROWID" if table["without_rowid"]
  options << "STRICT" if strict
  table["strict"] = strict
  table["sql"] = "CREATE TABLE #{name}(#{(columns.map { |column| column['definition'] } + table_constraints).join(', ')})#{options.empty? ? '' : " #{options.join(', ')}"}"
  table
end

def random_index_sql(random, table, number)
  columns = table["columns"].map { |column| column["name"] }
  picked = columns.sample(random.rand(1..[3, columns.size].min), random: random)
  terms = picked.map { |column| "#{column}#{random.rand(4).zero? ? ' COLLATE NOCASE' : ''}#{random.rand(3).zero? ? ' DESC' : ''}" }
  unique = random.rand(5).zero? ? "UNIQUE " : ""
  "CREATE #{unique}INDEX IF NOT EXISTS #{table['name']}_i#{number} ON #{table['name']}(#{terms.join(', ')})"
end

# --- Operations -----------------------------------------------------------

# SQLite's text for a REAL changed in 3.52 (17 digits when 15 do not
# read back the same double, and plain notation up to 1e17); a REAL bound
# for a TEXT-affinity column is kept to values every version renders the
# same way.
def text_affinity?(type)
  upper = type.upcase
  !upper.include?("INT") && %w[CHAR CLOB TEXT].any? { |word| upper.include?(word) }
end

def version_stable_real?(value)
  return true if value.zero? || value.infinite?
  value.abs < 1e12 && (value * 8).round == value * 8
end

def steer(random, column, typed)
  json = typed.first
  return typed unless json.is_a?(Hash) && json.key?("r") && text_affinity?(column["type"])
  value = [json["r"]].pack("H*").unpack1("G")
  version_stable_real?(value) ? typed : typed_real(random.rand(-99_999..99_999) / 8.0)
end

def row_values(random, table, alias_value)
  table["columns"].each_with_index.map do |column, index|
    if index == table["alias"]
      alias_value.nil? ? NULL_VALUE : typed_integer(alias_value)
    elsif table["key"].include?(index)
      steer(random, column, key_value(random))
    else
      steer(random, column, typed_value(random))
    end
  end
end

def insert_operation(random, table)
  name = table["name"]
  values = nil
  rowid = nil
  if table["without_rowid"]
    values = row_values(random, table, nil)
    table["keys"] << table["key"].map { |index| values[index] }
    sql = "INSERT INTO #{name} VALUES (#{values.map(&:last).join(', ')});"
  elsif table["alias"]
    chosen = random.rand(2).zero? ? nil : random.rand(-50..5_000)
    values = row_values(random, table, chosen)
    table["rowids"] << (chosen || table["next_rowid"])
    sql = "INSERT INTO #{name} VALUES (#{values.map(&:last).join(', ')});"
  else
    rowid = random.rand(2).zero? ? nil : random.rand(-50..5_000)
    values = row_values(random, table, nil)
    table["rowids"] << (rowid || table["next_rowid"])
    columns = table["columns"].map { |column| column["name"] }
    sql = if rowid
            "INSERT INTO #{name}(rowid, #{columns.join(', ')}) VALUES (#{rowid}, #{values.map(&:last).join(', ')});"
          else
            "INSERT INTO #{name} VALUES (#{values.map(&:last).join(', ')});"
          end
  end
  known = table["rowids"].max
  table["next_rowid"] = [table["next_rowid"], (known || 0) + 1].max
  [{ "op" => "insert", "table" => name, "rowid" => rowid&.to_s, "values" => values.map(&:first) }, sql]
end

def assignments(table, values)
  table["columns"].each_with_index.map { |column, index| "#{column['name']} = #{values[index].last}" }.join(", ")
end

def key_condition(table, key)
  table["key"].each_with_index.map { |index, position| "#{table['columns'][index]['name']} = #{key[position].last}" }.join(" AND ")
end

def change_operation(random, table, kind)
  name = table["name"]
  if table["without_rowid"]
    key = table["keys"].sample(random: random) || table["key"].map { key_value(random) }
    if kind == "delete"
      return [{ "op" => "delete_key", "table" => name, "key" => key.map(&:first) }, "DELETE FROM #{name} WHERE #{key_condition(table, key)};"]
    end
    values = row_values(random, table, nil)
    key.each_with_index { |value, position| values[table["key"][position]] = value } if random.rand(3) > 0
    table["keys"] << table["key"].map { |index| values[index] }
    return [{ "op" => "update_key", "table" => name, "key" => key.map(&:first), "values" => values.map(&:first) },
            "UPDATE #{name} SET #{assignments(table, values)} WHERE #{key_condition(table, key)};"]
  end
  rowid = table["rowids"].sample(random: random) || random.rand(1..100)
  if kind == "delete"
    return [{ "op" => "delete", "table" => name, "rowid" => rowid.to_s }, "DELETE FROM #{name} WHERE rowid = #{rowid};"]
  end
  new_rowid = table["alias"] && random.rand(5).zero? ? random.rand(-50..5_000) : rowid
  values = row_values(random, table, table["alias"] ? new_rowid : nil)
  table["rowids"] << new_rowid
  [{ "op" => "update", "table" => name, "rowid" => rowid.to_s, "values" => values.map(&:first) },
   "UPDATE #{name} SET #{assignments(table, values)} WHERE rowid = #{rowid};"]
end

def random_operation(random, tables, counters)
  choice = random.rand(100)
  if choice < 3 || tables.empty?
    name = "t#{counters[:table] += 1}"
    table = random_table(random, name)
    tables[name] = table
    return [{ "op" => "create_table", "sql" => table["sql"] }, "#{table['sql']};"]
  end
  table = tables.values.sample(random: random)
  if choice < 6
    sql = random_index_sql(random, table, counters[:index] += 1)
    (table["indexes"] ||= []) << sql[/INDEX IF NOT EXISTS (\S+)/, 1]
    return [{ "op" => "create_index", "sql" => sql }, "#{sql};"]
  end
  if choice < 8 && (table["indexes"] || []).any?
    index = table["indexes"].delete(table["indexes"].sample(random: random))
    return [{ "op" => "drop", "name" => index }, "DROP INDEX #{index};"]
  end
  if choice == 8 && tables.size > 1
    tables.delete(table["name"])
    return [{ "op" => "drop", "name" => table["name"] }, "DROP TABLE #{table['name']};"]
  end
  return change_operation(random, table, "delete") if choice < 25
  return change_operation(random, table, "update") if choice < 40
  insert_operation(random, table)
end

def random_sequence(random, size, wal = false)
  page_size = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536].sample(random: random)
  page_size = [512, 1024].sample(random: random) if size == "small"
  encoding = ["UTF-8", "UTF-16le", "UTF-16be"].sample(random: random)
  operations = []
  sql = +"PRAGMA page_size=#{page_size};\nPRAGMA encoding='#{encoding}';\n"
  # sqlite3 prints the mode; .output keeps it out of the error count.
  sql << ".output /dev/null\nPRAGMA journal_mode=WAL;\n.output\n" if wal
  tables = {}
  counters = { table: 0, index: 0 }
  units = size == "small" ? random.rand(2..6) : random.rand(5..40)
  bulk = size != "small" && random.rand(25).zero?
  units.times do |unit|
    transaction = random.rand(3).zero? || (bulk && unit == 1)
    count = transaction ? random.rand(2..(bulk && unit == 1 ? 1_500 : 30)) : 1
    if transaction
      operations << { "op" => "begin" }
      sql << "BEGIN;\n"
    end
    count.times do
      operation, statement = random_operation(random, tables, counters)
      operations << operation
      sql << statement << "\n"
    end
    next unless transaction
    ending = random.rand(5).zero? ? "rollback" : "commit"
    operations << { "op" => ending }
    sql << "#{ending.upcase};\n"
  end
  [{ "page_size" => page_size, "encoding" => encoding, "operations" => operations }, sql]
end

def run_sequences(out_dir, count, seed, start, size, wal = false)
  count.times do |offset|
    number = start + offset
    random = Random.new(seed + number)
    sequence, sql = random_sequence(random, size, wal)
    name = format("seq_%05d", number)
    File.write(File.join(out_dir, "#{name}.json"), JSON.generate(sequence.merge("seed" => seed + number)))
    File.write(File.join(out_dir, "#{name}.sql"), sql)
    database = File.join(out_dir, "#{name}.c.db")
    FileUtils.rm_f([database, "#{database}-journal", "#{database}-wal", "#{database}-shm"])
    _output, error, _status = Open3.capture3(SQLITE3, database, stdin_data: sql)
    File.write(File.join(out_dir, "#{name}.c.errors"), error.lines.count { |line| line =~ /error near line/i }.to_s)
  end
end

# --- Checks ---------------------------------------------------------------

def verify(database)
  base = database.sub(/\.db\z/, "")
  integrity, error, _status = Open3.capture3(SQLITE3, database, stdin_data: "PRAGMA integrity_check;")
  File.write("#{base}.integrity", error.empty? ? integrity : "#{integrity}#{error}")
  return unless error.empty?
  File.write("#{base}.schema", sqlite3(database, SCHEMA_SQL))
  dump = expected_dump_sql(database)
  File.write("#{base}.expected", dump.empty? ? "" : sqlite3(database, dump, "-list", "-bail"))
end

# The crash checks verify many small files whose schema is one of a few:
# each file costs one sqlite3 run for integrity_check and the schema, and
# one for the dump, whose SQL is built once per distinct schema. Files are
# checked on THREADS threads.
def run_verify_states(out_dir, suffix, threads)
  queue = Queue.new
  Dir.glob(File.join(out_dir, "*.#{suffix}.db")).sort.each { |database| queue << database }
  cache = {}
  lock = Mutex.new
  workers = Array.new(threads) do
    Thread.new do
      loop do
        database = begin
          queue.pop(true)
        rescue ThreadError
          break
        end
        base = database.sub(/\.db\z/, "")
        output, error, _status = Open3.capture3(SQLITE3, database, stdin_data: "PRAGMA integrity_check;\nSELECT '--schema';\n#{SCHEMA_SQL}\n")
        integrity, schema = output.split("--schema\n", 2)
        File.write("#{base}.integrity", error.empty? ? integrity.to_s : "#{integrity}#{error}")
        next unless error.empty? && integrity == "ok\n"
        dump = lock.synchronize { cache[schema] }
        unless dump
          dump = expected_dump_sql(database)
          lock.synchronize { cache[schema] = dump }
        end
        File.write("#{base}.expected", dump.empty? ? "" : sqlite3(database, dump, "-list", "-bail"))
      end
    end
  end
  workers.each(&:join)
end

def run_verify(out_dir, suffix)
  Dir.glob(File.join(out_dir, "*.#{suffix}.db")).sort.each { |database| verify(database) }
end

# --- The statement corpus -------------------------------------------------

TYPED_COLUMN_SQL = "CASE typeof(%1$s) WHEN 'null' THEN 'null' " \
                   "WHEN 'integer' THEN '{\"i\":\"' || %1$s || '\"}' " \
                   "WHEN 'real' THEN '{\"r\":\"' || hex(ieee754_to_blob(%1$s)) || '\"}' " \
                   "WHEN 'text' THEN '{\"t\":' || json_quote(%1$s) || '}' " \
                   "ELSE '{\"b\":\"' || lower(hex(%1$s)) || '\"}' END"

def run_corpus_rows(out_dir, corpus_path, seed)
  creates = File.readlines(corpus_path, chomp: true).grep(/\A\s*CREATE\s+(TABLE|UNIQUE INDEX|INDEX)\b/i).reject { |sql| sql.include?("?") }
  entry = run_corpus(out_dir, corpus_path, seed).first
  # Which statements sqlite3 accepted, in order, on a database of its own.
  probe = File.join(out_dir, "acceptance.db")
  FileUtils.rm_f(probe)
  accepted = creates.map do |sql|
    _output, _error, status = Open3.capture3(SQLITE3, probe, stdin_data: "#{sql.sub(/;?\s*\z/, '')};")
    status.success?
  end
  FileUtils.rm_f(probe)
  database = File.join(out_dir, "grant_corpus_schema.db")
  tables = JSON.parse(sqlite3(database, "SELECT name, sql FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid;", "-json").then { |out| out.strip.empty? ? "[]" : out })
  rows = []
  tables.each do |table|
    name = table["name"]
    columns = JSON.parse(sqlite3(database, "SELECT name, hidden FROM pragma_table_xinfo(#{quote_text(name)});", "-json"))
    without_rowid = table["sql"].match?(/WITHOUT\s+ROWID/i)
    stored = columns.reject { |column| column["hidden"].to_i.positive? }.map { |column| quote_name(column["name"]) }
    next if stored.empty?
    selected = (without_rowid ? ["'null'"] : ["'\"' || rowid || '\"'"]) + stored.map { |column| format(TYPED_COLUMN_SQL, column) }
    sql = "SELECT '[' || #{selected.join(" || ',' || ")} || ']' FROM #{quote_name(name)} ORDER BY #{without_rowid ? 1 : 'rowid'};"
    sqlite3(database, sql).each_line do |line|
      list = JSON.parse(line)
      rows << { "table" => name, "rowid" => list.first, "values" => list[1..], "generated" => columns.size != stored.size }
    end
  end
  verify(database)
  File.write(File.join(out_dir, "corpus.json"), JSON.generate("statements" => creates, "accepted" => accepted, "rows" => rows, "manifest" => entry))
end

if __FILE__ == $PROGRAM_NAME
  mode, out_dir = ARGV[0], ARGV[1]
  abort "usage: operations.rb sequences|verify|states|corpus OUT_DIR ..." unless %w[sequences verify states corpus].include?(mode) && out_dir
  FileUtils.mkdir_p(out_dir)
  case mode
  when "sequences"
    options = ARGV[2..].each_slice(2).to_h
    run_sequences(out_dir, Integer(options.fetch("--count", "10")), Integer(options.fetch("--seed")), Integer(options.fetch("--start", "0")), options.fetch("--size", "regular"), options.fetch("--wal", "0") == "1")
  when "verify"
    run_verify(out_dir, ARGV.fetch(2))
  when "states"
    run_verify_states(out_dir, ARGV.fetch(2), Integer(ARGV.fetch(3, "4")))
  else
    options = ARGV[2..].each_slice(2).to_h
    run_corpus_rows(out_dir, options.fetch("--corpus"), Integer(options.fetch("--seed", "20261122")))
  end
end
