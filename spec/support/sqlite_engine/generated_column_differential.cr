require "file_utils"
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"

# Runs statements over tables with STORED and VIRTUAL generated columns
# through Grant's engine and libsqlite3, and compares every statement's
# result code, error message, column names and typed rows. The files each
# engine wrote are then read by the other one and checked by the sqlite3
# shell's `PRAGMA integrity_check`.
module GeneratedColumnDifferential
  alias Engine = Grant::SQLite3::Engine

  def self.outcome(database : Engine::Database, sql : String) : String
    code, statement = database.prepare(sql)
    # C reports a schema error when it prepares the statement and Grant
    # when it first steps it; the code and message are what is compared.
    return "code=#{code} #{database.error_message}" unless code == Engine::OK_CODE
    # C prepares ALTER TABLE as a statement with a result column of its
    # own making; only its outcome is compared.
    column_count = sql.starts_with?("ALTER") ? 0 : statement.column_count
    list_of_columns = (0...column_count).map { |index| statement.column_name(index) }
    list_of_rows = [] of Array(String)
    step = Engine::ROW_CODE
    loop do
      step = statement.step
      break unless step == Engine::ROW_CODE
      list_of_rows << (0...statement.column_count).map do |column|
        case statement.column_type(column)
        when Grant::SQLite3::Type::INTEGER then "i:#{statement.column_int64(column)}"
        when Grant::SQLite3::Type::FLOAT   then "r:#{statement.column_double(column)}"
        when Grant::SQLite3::Type::BLOB    then "b:#{statement.column_blob(column).hexstring}"
        when Grant::SQLite3::Type::NULL    then "null"
        else                                    "t:#{statement.column_text(column)}"
        end
      end
    end
    message = step == Engine::DONE_CODE ? "" : database.error_message
    statement.finalize_statement
    return "code=#{step} #{message}" unless step == Engine::DONE_CODE
    "code=#{step} #{list_of_columns} #{list_of_rows}"
  end

  # The outcome of each of *list_of_statements* in one connection on *path*.
  def self.outcomes(engine : Engine, path : String, list_of_statements : Array(String)) : Array(String)
    code, database = engine.open(path)
    raise "open failed (#{code})" unless code == Engine::OK_CODE
    begin
      list_of_statements.map { |sql| "#{sql} => #{outcome(database, sql)}" }
    ensure
      database.close
    end
  end

  # What the sqlite3 shell's integrity_check says of the file at *path*.
  def self.shell_integrity_check(path : String) : String
    output = IO::Memory.new
    Process.run("/usr/bin/sqlite3", [path, "PRAGMA integrity_check;"], output: output, error: output)
    output.to_s.strip
  end

  private def self.compare(label : String, expected : Array(String), actual : Array(String), into : Array(String)) : Nil
    expected.zip(actual).each do |c, grant|
      next if c == grant
      # The two outcomes from just before their first difference: a row
      # list is long, and the difference is what a reader needs.
      shared = 0
      while shared < c.size && shared < grant.size && c[shared] == grant[shared]
        shared += 1
      end
      start = {shared - 60, 0}.max
      statement = c.partition(" => ")[0]
      into << "#{label}: #{statement[0, 300]}\n  C:     #{start > 0 ? "..." : ""}#{c[start, 400]}\n  Grant: #{start > 0 ? "..." : ""}#{grant[start, 400]}"
    end
  end

  # Every difference between the two engines: running *list_of_statements*
  # on a new file each; *list_of_queries* in a new connection on the file
  # each wrote, and on the file the other one wrote; and the sqlite3
  # shell's integrity_check of the file Grant wrote.
  def self.differences(list_of_statements : Array(String), list_of_queries : Array(String)) : Array(String)
    directory = File.tempname("generated-columns")
    Dir.mkdir_p(directory)
    c_path = File.join(directory, "c.db")
    grant_path = File.join(directory, "grant.db")
    c_engine = Engine::LibSQLite3Engine.new
    grant_engine = Engine::GrantEngine.new
    found = [] of String
    begin
      compare("statements", outcomes(c_engine, c_path, list_of_statements), outcomes(grant_engine, grant_path, list_of_statements), found)
      expected = outcomes(c_engine, c_path, list_of_queries)
      compare("own file", expected, outcomes(grant_engine, grant_path, list_of_queries), found)
      compare("Grant reads C's file", expected, outcomes(grant_engine, c_path, list_of_queries), found)
      compare("C reads Grant's file", expected, outcomes(c_engine, grant_path, list_of_queries), found)
      check = shell_integrity_check(grant_path)
      found << "sqlite3 integrity_check of Grant's file: #{check}" unless check == "ok"
      found
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # No REAL here: C keeps a whole number of a REAL column as an integer
  # marked real (MEM_IntReal), and a generated column that copies it into
  # an index or through a sorter reads back INTEGER or REAL by C's query
  # plan. The fixed cases of the spec cover REAL columns.
  COLUMN_TYPES        = ["INTEGER", "TEXT", "NUMERIC", "BLOB", "", "INT", "VARCHAR(10)"]
  STRICT_COLUMN_TYPES = ["INTEGER", "TEXT", "BLOB", "ANY", "INT"]
  EXPRESSIONS         = [
    "a * 2", "a + b", "a || b", "upper(b)", "length(b)", "coalesce(a, 0) + 1", "abs(a)",
    "CASE WHEN a > 5 THEN 'big' ELSE 'small' END", "a", "typeof(a)", "substr(b, 1, 2)", "a / 2.0", "a IS NULL",
    "cast(a AS TEXT)", "-a", "a % 3", "b LIKE 'a%'", "nullif(a, 3)", "hex(b)", "trim(b)", "a > b", "iif(a, b, c)",
    "c + 0.5", "instr(b, 'a')", "c", "b", "a * c", "typeof(b) || typeof(c)", "coalesce(b, c, a)", "a = c",
    "cast(b AS INTEGER)", "cast(c AS REAL)", "max(a, c)", "min(b, c)", "b COLLATE NOCASE", "+b", "length(c)",
    "'7'", "7", "7.0", "'x' || a", "a + '1'", "b + 0", "c * 1.0", "NULL", "quote(b)",
  ]
  VALUES = [
    "NULL", "0", "1", "2", "3", "5", "7", "-4", "10", "9007199254740993", "2.5", "-0.0", "3.0", "1e3", "'abc'", "'ABC'",
    "'a'", "''", "'7'", "'7.0'", "' 12 '", "'3abc'", "x'6162'", "x''", "'big'", "'Small'", "4611686018427387904", "0.1",
  ]

  private def self.pick(random : Random, list : Array(String)) : String
    list[random.rand(list.size)]
  end

  # A random table with generated columns, its indexes, rows, changes and
  # an ALTER TABLE ADD COLUMN, as statements; and the queries that read it.
  def self.random_case(random : Random) : {Array(String), Array(String)}
    strict = random.rand(8) == 0
    without_rowid = random.rand(6) == 0
    types = strict ? STRICT_COLUMN_TYPES : COLUMN_TYPES
    list_of_generated = [] of String
    list_of_names = ["a", "b", "c"]
    definitions = [] of String
    definitions << "id INTEGER PRIMARY KEY" if !without_rowid && random.rand(3) == 0
    key_column = without_rowid ? pick(random, list_of_names) : nil
    list_of_names.each do |name|
      # A STRICT table's ordinary and STORED columns are ANY here: only a
      # VIRTUAL column's type check is this differential's subject.
      definition = "#{name} #{strict ? "ANY" : pick(random, types)}".strip
      definition += " PRIMARY KEY" if name == key_column
      definition += " NOT NULL" if name != key_column && random.rand(12) == 0
      definition += " DEFAULT #{pick(random, VALUES)}" if random.rand(8) == 0
      definitions << definition
    end
    generated_count = random.rand(1..4)
    generated_count.times do |index|
      name = "g#{index + 1}"
      expression = pick(random, EXPRESSIONS)
      # Some expressions read a generated column made before this one (the
      # column list is sometimes shuffled, so it may be declared after).
      # Loops are left to the fixed cases.
      if index > 0 && random.rand(3) == 0
        expression = expression.sub(/\b[abc]\b/, "g#{random.rand(1..index)}")
      end
      storage = ["", " VIRTUAL", " STORED", " virtual"][random.rand(4)]
      type = pick(random, types)
      type = "ANY" if strict && storage == " STORED"
      definition = "#{name} #{type}".strip
      definition += random.rand(2) == 0 ? " GENERATED ALWAYS AS (#{expression})#{storage}" : " AS (#{expression})#{storage}"
      definition += " NOT NULL" if random.rand(15) == 0
      definition += " UNIQUE" if random.rand(15) == 0
      definition += " COLLATE NOCASE" if random.rand(10) == 0
      definition += " CHECK (#{name} IS NOT 13)" if random.rand(12) == 0
      list_of_generated << name
      list_of_names << name
      definitions << definition
    end
    definitions.shuffle!(random) if random.rand(4) == 0
    definitions << "CHECK (#{pick(random, list_of_generated)} IS NOT 'abcabc')" if random.rand(8) == 0
    options = [] of String
    options << "WITHOUT ROWID" if without_rowid
    options << "STRICT" if strict
    statements = ["CREATE TABLE t(#{definitions.join(", ")})#{options.empty? ? "" : " " + options.join(", ")}"]
    random.rand(0..3).times do |index|
      first = pick(random, list_of_generated)
      second = pick(random, list_of_names)
      terms = case random.rand(5)
              when 0 then "#{first}, #{second}"
              when 1 then "#{first} DESC"
              when 2 then "#{second}, #{first}"
              when 3 then "#{first} COLLATE NOCASE"
              else        first
              end
      where = random.rand(5) == 0 ? " WHERE #{pick(random, list_of_generated)} IS NOT NULL" : ""
      statements << "CREATE #{random.rand(6) == 0 ? "UNIQUE " : ""}INDEX i#{index} ON t(#{terms})#{where}"
    end
    writes = [] of String
    random.rand(3..14).times do
      verb = ["INSERT", "INSERT", "INSERT", "INSERT OR REPLACE", "INSERT OR IGNORE"][random.rand(5)]
      case random.rand(6)
      when 0 then writes << "#{verb} INTO t(a) VALUES (#{pick(random, VALUES)})"
      when 1 then writes << "#{verb} INTO t(b, a) VALUES (#{pick(random, VALUES)}, #{pick(random, VALUES)})"
      when 2 then writes << "#{verb} INTO t VALUES (#{pick(random, VALUES)}, #{pick(random, VALUES)}, #{pick(random, VALUES)})"
      else        writes << "#{verb} INTO t(a, b, c) VALUES (#{pick(random, VALUES)}, #{pick(random, VALUES)}, #{pick(random, VALUES)})"
      end
    end
    random.rand(0..5).times do
      generated = pick(random, list_of_generated)
      source = ["a", "b", "c"][random.rand(3)]
      case random.rand(9)
      when 0 then writes << "UPDATE t SET #{source} = #{pick(random, VALUES)}"
      when 1 then writes << "UPDATE t SET #{source} = #{pick(random, VALUES)} WHERE #{generated} > #{pick(random, VALUES)}"
      when 2 then writes << "UPDATE OR REPLACE t SET #{source} = #{pick(random, VALUES)} WHERE #{generated} IS NOT NULL"
      when 3 then writes << "DELETE FROM t WHERE #{generated} = #{pick(random, VALUES)}"
      when 4 then writes << "UPDATE t SET #{generated} = 1"
      when 5 then writes << "INSERT INTO t(a, #{generated}) VALUES (1, 2)"
      when 6 then writes << "UPDATE t SET a = b, b = a WHERE #{generated} < #{pick(random, VALUES)} RETURNING #{generated}, typeof(#{generated})"
      when 7 then writes << "DELETE FROM t WHERE #{generated} IS NULL RETURNING *"
      else        writes << "INSERT INTO t(a, b) VALUES (#{pick(random, VALUES)}, #{pick(random, VALUES)}) ON CONFLICT DO UPDATE SET c = excluded.#{generated}"
      end
    end
    writes.shuffle!(random)
    statements.concat(writes)
    if random.rand(2) == 0
      storage = ["", " VIRTUAL", " STORED"][random.rand(3)]
      extra = "h #{strict ? "ANY" : pick(random, types)} AS (#{pick(random, EXPRESSIONS).sub(/\b[abc]\b/) { |name| random.rand(3) == 0 ? pick(random, list_of_generated) : name }})#{storage}"
      extra += " NOT NULL" if random.rand(10) == 0
      statements << "ALTER TABLE t ADD COLUMN #{extra}"
      statements << "CREATE INDEX ih ON t(h)" if random.rand(2) == 0
      statements << "INSERT INTO t(a, b, c) VALUES (#{pick(random, VALUES)}, #{pick(random, VALUES)}, #{pick(random, VALUES)})"
      statements << "UPDATE t SET a = #{pick(random, VALUES)} WHERE h IS NOT NULL"
      list_of_generated << "h"
      list_of_names << "h"
    end
    full_order = list_of_names.join(", ")
    generated = pick(random, list_of_generated)
    other = pick(random, list_of_generated)
    queries = [
      "SELECT * FROM t ORDER BY #{full_order}",
      "SELECT #{list_of_generated.map { |name| "typeof(#{name})" }.join(", ")} FROM t ORDER BY #{full_order}",
      "SELECT #{generated}, a FROM t WHERE #{generated} > #{pick(random, VALUES)} ORDER BY #{full_order}",
      "SELECT #{generated} FROM t WHERE #{generated} = #{pick(random, VALUES)} ORDER BY #{full_order}",
      "SELECT a, b, c FROM t WHERE #{generated} BETWEEN #{pick(random, VALUES)} AND #{pick(random, VALUES)} ORDER BY #{full_order}",
      # Which of several values equal under the column's collation a group
      # shows follows C's choice of index, so groups are made of exact values.
      "SELECT hex(#{generated}), typeof(#{generated}), count(*), count(#{other}), max(a) FROM t GROUP BY 1, 2 ORDER BY 1, 2",
      "SELECT DISTINCT hex(#{generated}), typeof(#{generated}) FROM t ORDER BY 1 DESC, 2",
      "SELECT count(*), count(#{generated}), total(#{other}) FROM t WHERE #{other} IS NOT NULL",
      "SELECT x.#{generated}, y.#{other} FROM t AS x LEFT JOIN t AS y ON y.#{generated} = x.#{other} ORDER BY 1, 2, x.a, x.b, x.c, y.a, y.b, y.c",
      "SELECT #{generated} FROM t WHERE #{generated} IN (SELECT #{other} FROM t) ORDER BY #{full_order}",
      "SELECT #{generated} || '-', #{other} + 1 FROM (SELECT * FROM t ORDER BY #{full_order} LIMIT 5)",
      "SELECT cid, name, type, dflt_value, pk, hidden FROM pragma_table_xinfo('t')",
      "PRAGMA integrity_check",
      "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name",
    ]
    {statements, queries}
  end
end
