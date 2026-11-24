# Compares the JSON functions of Grant's SQLite engine with C SQLite's on
# generated calls.
#
#   crystal-alpha run scripts/sqlite_engine_json_differential.cr -- random SEED COUNT REPORT_DIR
#     COUNT generated statements: random JSON documents (nesting, unicode,
#     escapes, JSON5 forms, numbers of every shape, some malformed), random
#     paths that exist and that do not, every JSON function that builds,
#     edits or reads JSON, the jsonb_ forms and the aggregates, with calls
#     nested in one another so that argument subtypes and C's parse cache
#     are exercised. Writes summary.txt and differences.txt to REPORT_DIR
#     and exits 1 when any statement differs.
#
#   crystal-alpha run scripts/sqlite_engine_json_differential.cr -- query SQL
#     Prints both engines' outcome for one statement on the fixture table.
#
# Values compare typed and byte for byte (a JSONB result as its bytes),
# errors by message. Link a pinned libsqlite3 with
# --link-flags "-L DIR -Wl,-rpath,DIR".
require "file_utils"
require "../spec/support/sqlite_engine/query_oracle"

private alias Value = Grant::SQLiteEngine::Value
private alias Outcome = SQLiteQueryOracle::Outcome

# Generates JSON documents, paths and SQL calls from a seeded generator.
class JsonCallGenerator
  KEYS = ["a", "b", "c", "key", "a b", "a.b", "", "é", "k\\\"q", "\\u0041", "x[0]", "n1", "$", "日本", "tab\\t"]

  STRINGS = ["", "x", "hello world", "é", "日本語", "😀", "q\\\"uote", "back\\\\slash", "line\\nbreak", "\\u00e9", "\\ud83d\\ude00",
             "sl/ash", "\\/", "it's", "tab\\there", "\\u0001", "a\\u0000b", "{\\\"not\\\":1}", "[1]", "null", "long " * 12,
             "abcdefghijklmnopqrstuvwxyz0123456789" * 3]

  NUMBERS = ["0", "-0", "1", "-1", "42", "9223372036854775807", "-9223372036854775808", "9223372036854775808",
             "123456789012345678901234567890", "1.5", "-3.25", "0.1", "1e10", "1E-5", "2.5e+300", "1e400", "-1e400", "0.0",
             "1.0", "100000000000000000000.0", "3.141592653589793238", "5e-324", "1e0"]

  JSON5_VALUES = ["0x1F", "-0X10", "+7", ".5", "5.", "-.5", "Infinity", "-Infinity", "NaN", "'single'", "'it\\'s'",
                  "\"\\x41\"", "\"\\v\"", "\"a\\\nb\"", "0xFFFFFFFFFFFFFFFFF", "+Infinity", "\"\\0\""]

  MALFORMED = ["{", "[1,2", "{\"a\" 1}", "[1,,2]", "nul", "", "   ", "{\"a\":01}", "[1 2]", "\"unterminated", "{\"a\":1} x", "]", "{a:}"]

  BAD_PATHS = ["a", "$a", "$.", "$[", "$[x]", "$[1", "$.\"open", "$[#-]", "$[-1]", "", "$..a", "$[1]x", "$[#x]", "$.a[", "$ ", "x$"]

  SQL_VALUES = ["NULL", "1", "-7", "0", "9223372036854775807", "-9223372036854775808", "1.5", "-0.0", "0.1", "1e300", "1e999",
                "-1e999", "123456789012345680.0", "1e15", "1e16", "1.0e-10", "3.0", "2.5e-5", "'text'", "''", "'q\"uote'",
                "'back\\slash'", "'it''s'", "'é日本😀'", "'[1,2]'", "'{\"a\":1}'", "'null'", "'12'", "char(1, 9, 10, 31)",
                "'a' || char(0) || 'b'", "x'1331'", "x'cb1b31'", "x'ff'", "x''", "x'00'", "x'6b17613133'", "x'0c'",
                "'long text value that goes on and on, well past what fits in a small buffer, to make results large'",
                "1 = 1", "length('abc')", "upper('json')", "CAST('5' AS INTEGER)", "CAST(2 AS REAL)", "CAST('[1]' AS BLOB)"]

  getter random : Random

  def initialize(seed : UInt64)
    @random = Random.new(seed)
  end

  def pick(list : Array(String)) : String
    list[@random.rand(list.size)]
  end

  def chance(numerator : Int32, denominator : Int32) : Bool
    @random.rand(denominator) < numerator
  end

  def self.sql_text(text : String) : String
    "'#{text.gsub('\'', "''")}'"
  end

  # A JSON value as text, and the paths that exist in it.
  def document(depth : Int32, path : String, list_of_paths : Array(String)) : String
    list_of_paths << path
    roll = @random.rand(100)
    if depth > 0 && roll < 30
      count = @random.rand(5)
      members = (0...count).map do
        key = pick(KEYS)
        key_path = key.matches?(/\A[a-z0-9]+\z/) && chance(2, 3) ? "#{path}.#{key}" : "#{path}.\"#{key}\""
        "\"#{key}\"#{space}:#{space}#{document(depth - 1, key_path, list_of_paths)}"
      end
      "{#{space}#{members.join(",#{space}")}#{space}}"
    elsif depth > 0 && roll < 60
      count = @random.rand(5)
      members = (0...count).map { |index| document(depth - 1, "#{path}[#{index}]", list_of_paths) }
      "[#{space}#{members.join(",#{space}")}#{space}]"
    elsif roll < 75
      "\"#{pick(STRINGS)}\""
    elsif roll < 90
      pick(NUMBERS)
    elsif roll < 96
      pick(["true", "false", "null"])
    else
      pick(JSON5_VALUES)
    end
  end

  private def space : String
    chance(1, 6) ? pick([" ", "  ", "\n", "\t"]) : ""
  end

  # A document as SQL text, with paths into it.
  def document_literal(list_of_paths : Array(String)) : String
    return JsonCallGenerator.sql_text(pick(MALFORMED)) if chance(1, 40)
    text = document(1 + @random.rand(4), "$", list_of_paths)
    text = "{a:#{text},'b':[1,2,],/*c*/ c:0x10}" if chance(1, 30)
    text = " #{text}\n" if chance(1, 20)
    # A large document: its text results pass JsonString's static space.
    if chance(1, 4)
      padding = (0...(2 + @random.rand(6))).map { |index| "\"pad#{index}\":\"#{pick(STRINGS)}\"" }.join(",")
      text = "{\"doc\":#{text},#{padding}}"
      list_of_paths.map! { |path| "$.doc#{path[1..]}" }
      list_of_paths << "$.pad0" << "$.pad1"
    end
    JsonCallGenerator.sql_text(text)
  end

  def path(list_of_paths : Array(String)) : String
    roll = @random.rand(100)
    text = if roll < 50 && !list_of_paths.empty?
             pick(list_of_paths)
           elsif roll < 70 && !list_of_paths.empty?
             "#{pick(list_of_paths)}#{path_step}#{chance(1, 3) ? path_step : ""}"
           elsif roll < 80
             "$#{path_step}#{chance(1, 2) ? path_step : ""}#{chance(1, 4) ? path_step : ""}"
           elsif roll < 86
             "$"
           elsif roll < 94
             pick(BAD_PATHS)
           else
             return pick(["NULL", "1", "2.5", "x'24'"])
           end
    JsonCallGenerator.sql_text(text)
  end

  private def path_step : String
    case @random.rand(9)
    when 0 then ".#{pick(["a", "b", "c", "new", "n1", "key", "zz"])}"
    when 1 then ".\"#{pick(KEYS)}\""
    when 2 then "[#{@random.rand(6)}]"
    when 3 then "[#]"
    when 4 then "[#-#{@random.rand(4)}]"
    when 5 then "[0]"
    when 6 then ".\"a\\\"b\""
    when 7 then ".\"\\u0061\""
    else        ".é"
    end
  end

  # An SQL expression whose value is JSON (text with the JSON subtype, or
  # JSONB), or a document literal.
  def json_expression(depth : Int32, list_of_paths : Array(String)) : String
    return document_literal(list_of_paths) if depth <= 0 || chance(2, 5)
    call(depth - 1, list_of_paths, json_only: true)
  end

  # An SQL value for a VALUE argument.
  def value_expression(depth : Int32) : String
    roll = @random.rand(100)
    return pick(SQL_VALUES) if depth <= 0 || roll < 55
    inner_paths = [] of String
    if roll < 85
      call(depth - 1, inner_paths, json_only: false)
    elsif roll < 90
      "CASE WHEN #{@random.rand(2)} THEN #{json_expression(depth - 1, inner_paths)} ELSE #{pick(SQL_VALUES)} END"
    elsif roll < 94
      "coalesce(NULL, #{json_expression(depth - 1, inner_paths)})"
    elsif roll < 97
      "iif(#{@random.rand(2)}, #{json_expression(depth - 1, inner_paths)}, #{pick(SQL_VALUES)})"
    else
      "(#{json_expression(depth - 1, inner_paths)} || '')"
    end
  end

  EDITORS    = %w[json_set json_insert json_replace jsonb_set jsonb_insert jsonb_replace]
  JSON_CALLS = %w[json jsonb array object quote edit remove patch extract arrow]
  ANY_CALLS  = %w[json jsonb array object quote edit edit edit remove remove patch patch extract extract arrow arrow2 pretty
    type valid length error_position]

  # One JSON function call.
  def call(depth : Int32, list_of_paths : Array(String), json_only : Bool) : String
    kind = pick(json_only ? JSON_CALLS : ANY_CALLS)
    binary = chance(1, 3)
    prefix = binary ? "jsonb" : "json"
    case kind
    when "json"  then "json(#{json_expression(depth, list_of_paths)})"
    when "jsonb" then "jsonb(#{json_expression(depth, list_of_paths)})"
    when "array"
      list_of_paths.clear
      "#{prefix}_array(#{(0...@random.rand(5)).map { value_expression(depth) }.join(", ")})"
    when "object"
      list_of_paths.clear
      count = @random.rand(4)
      arguments = (0...count).flat_map do
        label = chance(1, 25) ? pick(["1", "NULL", "x'61'", "2.5"]) : JsonCallGenerator.sql_text(pick(KEYS).gsub("\\\"", "\"").gsub("\\t", "\t"))
        [label, value_expression(depth)]
      end
      arguments << pick(SQL_VALUES) if chance(1, 40)
      "#{prefix}_object(#{arguments.join(", ")})"
    when "quote"
      list_of_paths.clear
      "json_quote(#{value_expression(depth)})"
    when "edit"
      name = pick(EDITORS)
      document = json_expression(depth, list_of_paths)
      count = chance(1, 30) ? 0 : 1 + @random.rand(3)
      arguments = [document]
      count.times do
        arguments << path(list_of_paths)
        arguments << value_expression(depth)
      end
      arguments << path(list_of_paths) if chance(1, 40)
      "#{name}(#{arguments.join(", ")})"
    when "remove"
      document = json_expression(depth, list_of_paths)
      count = chance(1, 30) ? 0 : 1 + @random.rand(3)
      "#{prefix}_remove(#{([document] + (0...count).map { path(list_of_paths) }).join(", ")})"
    when "patch"
      other_paths = [] of String
      target = chance(1, 30) ? "NULL" : json_expression(depth, list_of_paths)
      patch = chance(1, 30) ? "NULL" : (chance(1, 2) ? patch_literal : json_expression(depth, other_paths))
      "#{prefix}_patch(#{target}, #{patch})"
    when "extract"
      document = json_expression(depth, list_of_paths)
      count = chance(1, 5) ? 2 + @random.rand(2) : 1
      "#{prefix}_extract(#{([document] + (0...count).map { path(list_of_paths) }).join(", ")})"
    when "arrow"  then "(#{json_expression(depth, list_of_paths)} -> #{path(list_of_paths)})"
    when "arrow2" then "(#{json_expression(depth, list_of_paths)} ->> #{path(list_of_paths)})"
    when "pretty"
      indent = chance(1, 3) ? ", #{pick(["'  '", "char(9)", "''", "NULL", "'--'", "2"])}" : ""
      "json_pretty(#{json_expression(depth, list_of_paths)}#{indent})"
    when "type"   then "json_type(#{json_expression(depth, list_of_paths)}#{chance(1, 2) ? ", #{path(list_of_paths)}" : ""})"
    when "valid"  then "json_valid(#{json_expression(depth, list_of_paths)}#{chance(1, 2) ? ", #{1 + @random.rand(15)}" : ""})"
    when "length" then "json_array_length(#{json_expression(depth, list_of_paths)}#{chance(1, 2) ? ", #{path(list_of_paths)}" : ""})"
    else               "json_error_position(#{json_expression(depth, list_of_paths)})"
    end
  end

  private def patch_literal : String
    members = (0...@random.rand(4)).map do
      value = chance(1, 3) ? "null" : (chance(1, 3) ? "{\"#{pick(KEYS)}\":#{chance(1, 2) ? "null" : pick(NUMBERS)}}" : document(1, "$", [] of String))
      "\"#{pick(KEYS)}\":#{value}"
    end
    JsonCallGenerator.sql_text("{#{members.join(",")}}")
  end

  AGGREGATE_VALUES = ["v", "j", "json(j)", "k", "id", "r", "b", "json_extract(j, '$.a')", "j -> '$'", "j ->> '$.a'", "json_quote(v)",
                      "json_array(id, v)", "json_object('id', id, 'j', json(j))", "CASE WHEN id % 2 THEN json(j) ELSE v END",
                      "jsonb(j)", "NULL", "json_set(j, '$.n', id)"]

  # One statement over the fixture table t(id, k, v, j, r, b).
  def table_statement : String
    filter = chance(1, 3) ? " FILTER (WHERE id % #{2 + @random.rand(3)} > 0)" : ""
    where = chance(1, 3) ? " WHERE id #{pick(["<", ">", "!="])} #{@random.rand(14)}" : ""
    group = chance(1, 2) ? " GROUP BY id % #{1 + @random.rand(4)} ORDER BY id % 4, 1" : ""
    group = " GROUP BY k ORDER BY k" if chance(1, 8)
    distinct = chance(1, 8) ? "DISTINCT " : ""
    case @random.rand(8)
    when 0, 1
      name = pick(["json_group_array", "jsonb_group_array"])
      "SELECT #{name}(#{distinct}#{pick(AGGREGATE_VALUES)})#{filter} FROM t#{where}#{group}"
    when 2, 3
      name = pick(["json_group_object", "jsonb_group_object"])
      "SELECT #{name}(#{pick(["k", "v", "id", "k || id", "NULL", "j", "b"])}, #{pick(AGGREGATE_VALUES)})#{filter} FROM t#{where}#{group}"
    when 4
      outer = pick(["json_array(%s, 1)", "json_quote(%s)", "json_set('{}', '$.g', %s)", "subtype(%s)", "typeof(%s)", "json_type(%s)", "jsonb(%s)", "json(%s)"])
      inner = "#{pick(["json_group_array", "jsonb_group_array"])}(#{pick(AGGREGATE_VALUES)})"
      "SELECT #{outer.sub("%s", inner)} FROM t#{where}#{group}"
    when 5
      "SELECT id, #{pick(EDITORS)}(j, #{path(["$.a", "$.b", "$[0]", "$.n", "$.a[0]"])}, #{pick(AGGREGATE_VALUES - ["NULL"])}) FROM t#{where} ORDER BY id"
    when 6
      "SELECT id, json_remove(j, #{path(["$.a", "$.b", "$[0]", "$[#-1]"])}), json_patch(j, #{patch_literal}), json_pretty(j) FROM t#{where} ORDER BY id"
    else
      "SELECT id, json_array(v, r, b, json(j)), json_object(k, v, 'j', j -> '$'), json_quote(r) FROM t#{where} ORDER BY id"
    end
  end

  def statement : String
    return table_statement if chance(1, 8)
    list_of_paths = [] of String
    expression = call(1 + @random.rand(3), list_of_paths, json_only: false)
    case @random.rand(12)
    when 0 then "SELECT subtype(#{expression})"
    when 1 then "SELECT typeof(#{expression})"
    when 2 then "SELECT #{expression}, #{call(1, [] of String, json_only: false)}"
    else        "SELECT #{expression}"
    end
  end
end

module JsonDifferential
  FIXTURE = <<-SQL
    CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT, v, j TEXT, r REAL, b BLOB);
    INSERT INTO t VALUES (1, 'a', 'one', '{"a":1,"b":[1,2]}', 1.5, x'1331');
    INSERT INTO t VALUES (2, 'b', 2, '[1,2,3]', -0.0, NULL);
    INSERT INTO t VALUES (3, 'a', NULL, '{"a":{"b":null},"n":"x\\"y"}', 1e300, x'0c');
    INSERT INTO t VALUES (4, NULL, 'q"uote', '"text"', NULL, x'cb1b31');
    INSERT INTO t VALUES (5, 'c d', 3.25, '{"a":[{"deep":[1,[2,[3]]]}],"é":"日本"}', 100.0, NULL);
    INSERT INTO t VALUES (6, 'b', '[1]', '[]', 0.1, x'1331');
    INSERT INTO t VALUES (7, '', 'one', '{}', 1e15, NULL);
    INSERT INTO t VALUES (8, 'é', '{"x":1}', '12', 1e16, x'00');
    INSERT INTO t VALUES (9, 'a', 9223372036854775807, 'null', 123456789.125, NULL);
    INSERT INTO t VALUES (10, 'k"q', 'tab' || char(9), '{"a":"this is a long value used to push results past one hundred bytes of text","b":[10,20,30,40,50,60,70,80,90]}', 2.0, NULL);
    INSERT INTO t VALUES (11, 'a', 'one', '{a:1,''b'':0x10}', 5.0, NULL);
    INSERT INTO t VALUES (12, 'z', 1.0, '[1,[2,[3,[4]]]]', -7.75, x'1331');
    SQL

  class Pair
    getter oracle : SQLiteQueryOracle::Connection
    getter session : Grant::SQLiteEngine::Query::Session

    def initialize(directory : String)
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "json-differential-#{Process.pid}.db")
      File.delete?(path)
      @oracle = SQLiteQueryOracle::Connection.new(path)
      if message = @oracle.exec(FIXTURE)
        raise "fixture setup failed: #{message}"
      end
      @session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open(path))
    end

    def compare(sql : String) : {Outcome, Outcome, String?}
      expected = @oracle.query(sql)
      actual = begin
        SQLiteQueryOracle.engine_query(@session, sql)
      rescue error : Exception
        Outcome.new([] of String, [] of Array(Value), "raised #{error.class}: #{error.message}", [] of Bool)
      end
      {expected, actual, SQLiteQueryOracle.difference(expected, actual, ordered: true)}
    end
  end

  def self.describe(outcome : Outcome) : String
    return "error #{outcome.error.inspect}" if outcome.error
    outcome.list_of_rows.map { |row| SQLiteQueryOracle.row_token(row) }.join(" / ")
  end

  def self.random(seed : UInt64, count : Int32, report_directory : String) : Bool
    pair = Pair.new(report_directory)
    generator = JsonCallGenerator.new(seed)
    list_of_differences = [] of String
    counts = Hash(String, Int32).new(0)
    errors = 0
    count.times do
      sql = generator.statement
      expected, _actual, difference = pair.compare(sql)
      errors += 1 if expected.error
      sql.scan(/(jsonb?(?:_[a-z_]+)?)\(|->>?/) { |match| counts[match[1]? || match[0]] += 1 }
      if difference
        list_of_differences << "#{sql}\n    #{difference}"
      end
    end
    summary = String.build do |io|
      io << "JSON differential against libsqlite3 " << SQLiteSQLOracle.version.split(" ").first << "\n"
      io << "seed " << seed << ", statements " << count << ", statements where C reports an error " << errors << "\n"
      io << "differences " << list_of_differences.size << "\n"
      io << "calls by function:\n"
      counts.to_a.sort_by { |(name, _)| name }.each { |(name, total)| io << "  " << name << " " << total << "\n" }
    end
    File.write(File.join(report_directory, "summary-#{seed}.txt"), summary)
    File.write(File.join(report_directory, "differences-#{seed}.txt"), list_of_differences.first(500).join("\n") + "\n")
    STDOUT.puts summary
    list_of_differences.empty?
  end

  def self.query(sql : String) : Nil
    pair = Pair.new(Dir.tempdir)
    expected, actual, difference = pair.compare(sql)
    STDOUT.puts "C:      #{describe(expected)}"
    STDOUT.puts "engine: #{describe(actual)}"
    STDOUT.puts(difference ? "DIFFERENT: #{difference}" : "SAME")
  end
end

case ARGV[0]?
when "random"
  exit(JsonDifferential.random(ARGV[1].to_u64, ARGV[2].to_i, ARGV[3]) ? 0 : 1)
when "query"
  ARGV[1..].each { |sql| JsonDifferential.query(sql) }
else
  STDERR.puts "usage: random SEED COUNT REPORT_DIR | query SQL..."
  exit 2
end
