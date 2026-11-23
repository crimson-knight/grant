# Compares the engine's SQL parser with C SQLite's.
#
#   crystal-alpha run scripts/sqlite_engine_sql_oracle.cr -- corpus FILE REPORT_DIR
#     Every line of FILE is one statement: the two parsers' verdicts must
#     agree, each parsed statement is printed back and C must give the
#     printed text the same verdict, and where C prepares both texts against
#     a database holding the file's schema their EXPLAIN bytecode must match.
#
#   crystal-alpha run scripts/sqlite_engine_sql_oracle.cr -- records FILE REPORT_DIR
#     Every line of FILE is a JSON object {"source": ..., "sql": ...}; the two
#     parsers' verdicts must agree.
#
#   crystal-alpha run scripts/sqlite_engine_sql_oracle.cr -- fuzz CORPUS COUNT SEED REPORT_DIR
#     Parses COUNT generated inputs (mutated corpus statements, random
#     grammar, deep nesting, long and binary text): any exception other than
#     a ParseError is a crash, and each input's parse time is recorded.
#     Verdicts are also compared with C's.
#
#   crystal-alpha run scripts/sqlite_engine_sql_oracle.cr -- bench CORPUS ROUNDS REPORT_DIR
#     Times the engine's parse of every corpus statement against C's
#     sqlite3_prepare_v2 plus sqlite3_finalize on a database holding the
#     corpus schema, the two interleaved round by round.
#
# Link a pinned libsqlite3 with --link-flags "-L DIR -Wl,-rpath,DIR".
require "json"
require "../spec/support/sqlite_engine/sql_oracle"

private alias SQL = Grant::SQLiteEngine::SQL
private alias Verdict = SQLiteSQLOracle::Verdict

record SQLRecord, source : String, sql : String do
  include JSON::Serializable
end

class SQLOracleComparison
  getter verdict_counts = Hash(String, Int32).new(0)
  getter list_of_disagreements = [] of String
  getter list_of_undetermined = [] of String
  getter list_of_round_trip_failures = [] of String
  getter list_of_bytecode_differences = [] of String
  getter message_matches = 0
  getter message_compared = 0
  getter printed_checked = 0
  getter bytecode_compared = 0

  def compare(source : String, sql : String) : SQL::Statement?
    c_outcome = SQLiteSQLOracle.verdict(sql)
    engine_outcome = SQLiteSQLOracle.engine_verdict(sql)
    @verdict_counts["c #{c_outcome.verdict.to_s.downcase}, engine #{engine_outcome.verdict.to_s.downcase}"] += 1
    if c_outcome.verdict.rejected? && engine_outcome.verdict.rejected?
      @message_compared += 1
      @message_matches += 1 if c_outcome.message == engine_outcome.message
    end
    if c_outcome.verdict.undetermined?
      @list_of_undetermined << "#{source}\n  c: #{c_outcome.message}\n  engine: #{engine_outcome.verdict} #{engine_outcome.message}\n  sql: #{sql}"
    end
    unless c_outcome.verdict.undetermined? || c_outcome.verdict == engine_outcome.verdict
      @list_of_disagreements << "#{source}\n  c: #{c_outcome.verdict} #{c_outcome.message}\n  engine: #{engine_outcome.verdict} #{engine_outcome.message}\n  sql: #{sql}"
    end
    return unless engine_outcome.verdict.accepted?
    SQL::Parser.parse(sql)
  rescue error
    @list_of_disagreements << "#{source}\n  engine raised #{error.class}: #{error.message}\n  sql: #{sql}"
    nil
  end

  # The printed statement parses to an equal tree and C gives it the
  # original's verdict.
  def check_printed(source : String, sql : String, statement : SQL::Statement) : String?
    printed = statement.to_sql
    @printed_checked += 1
    if SQL::Parser.parse(printed) != statement
      @list_of_round_trip_failures << "#{source}: tree differs\n  sql: #{sql}\n  printed: #{printed}"
      return
    end
    original = SQLiteSQLOracle.verdict(sql)
    again = SQLiteSQLOracle.verdict(printed)
    unless original.verdict == again.verdict
      @list_of_round_trip_failures << "#{source}: C verdict #{original.verdict} became #{again.verdict} (#{again.message})\n  sql: #{sql}\n  printed: #{printed}"
    end
    printed
  rescue error
    @list_of_round_trip_failures << "#{source}: #{error.class}: #{error.message}\n  sql: #{sql}"
    nil
  end

  def check_bytecode(database : SQLiteSQLOracle::LibOracle::Database, source : String, sql : String, printed : String) : Nil
    original = SQLiteSQLOracle.bytecode(database, sql)
    again = SQLiteSQLOracle.bytecode(database, printed)
    return unless original && again
    @bytecode_compared += 1
    return if without_sql_text(original) == without_sql_text(again)
    @list_of_bytecode_differences << "#{source}\n  sql: #{sql}\n  printed: #{printed}"
  end

  # The Init opcode carries the statement text itself.
  private def without_sql_text(rows : Array(String)) : Array(String)
    rows.map { |row| row.starts_with?("Init|") ? row.split('|').first(4).join('|') : row }
  end

  def report(io : IO, total : Int32) : Nil
    io.puts "C SQLite #{SQLiteSQLOracle.version}"
    io.puts "statements: #{total}"
    @verdict_counts.to_a.sort.each { |label, count| io.puts "  #{label}: #{count}" }
    io.puts "verdict disagreements (C undetermined excluded): #{@list_of_disagreements.size}"
    io.puts "both rejected, same message: #{@message_matches} of #{@message_compared}"
    io.puts "printed back and checked: #{@printed_checked}, failures: #{@list_of_round_trip_failures.size}"
    io.puts "EXPLAIN bytecode compared: #{@bytecode_compared}, differences: #{@list_of_bytecode_differences.size}"
  end

  def write_details(directory : Path) : Nil
    Dir.mkdir_p(directory)
    File.write(directory / "disagreements.txt", @list_of_disagreements.join("\n\n") + "\n")
    File.write(directory / "undetermined.txt", @list_of_undetermined.join("\n\n") + "\n")
    File.write(directory / "round_trip_failures.txt", @list_of_round_trip_failures.join("\n\n") + "\n")
    File.write(directory / "bytecode_differences.txt", @list_of_bytecode_differences.join("\n\n") + "\n")
  end
end

# Generates hostile and near-valid SQL for the parser.
class SQLFuzzer
  KEYWORDS = Grant::SQLiteEngine::SQL::Keywords::TABLE.keys
  PIECES   = ["(", ")", ",", ";", "'", "\"", "`", "[", "]", "?", "?1", ":a", "@b", "$c", "*", "/*", "--", "\n",
              "x'00'", "1e999", "0x", "1_000", "NULL", "-", "~", "||", "->>", "==", "<>", "!", "#1", "\u{00e9}", "mode = ARGV[0]?"]

  def initialize(@list_of_statements : Array(String), @count : Int32, @seed : UInt64)
    @random = Random::PCG32.new(@seed)
  end

  def run(comparison : SQLOracleComparison, directory : Path) : String
    crashes = [] of String
    kinds = Hash(String, Int32).new(0)
    slowest = {0.0, ""}
    accepted = 0
    peak_heap = 0_u64
    started = Time.instant
    @count.times do |index|
      kind, sql = generate
      kinds[kind] += 1
      before = Time.instant
      begin
        SQL::Parser.parse(sql)
        accepted += 1
      rescue SQL::ParseError
      rescue error
        crashes << "#{kind} ##{index}: #{error.class}: #{error.message}\n  sql: #{sql[0, 500].inspect}"
      end
      elapsed = (Time.instant - before).total_seconds
      slowest = {elapsed, "#{kind}: #{sql[0, 300].inspect} (#{sql.bytesize} bytes)"} if elapsed > slowest[0]
      comparison.compare("fuzz ##{index} (#{kind})", sql) if index % 10 == 0 && sql.bytesize < 100_000
      if index % 10_000 == 0
        peak_heap = Math.max(peak_heap, GC.stats.heap_size)
        STDERR.puts "fuzz: #{index} inputs" if index % 100_000 == 0
      end
    end
    File.write(directory / "crashes.txt", crashes.join("\n\n") + "\n")
    comparison.write_details(directory / "differential")
    String.build do |io|
      io.puts "seed: #{@seed}"
      io.puts "inputs: #{@count} (#{kinds.to_a.sort.map { |kind, number| "#{kind} #{number}" }.join(", ")})"
      io.puts "accepted by the engine: #{accepted}"
      io.puts "crashes (exceptions other than ParseError): #{crashes.size}"
      io.puts "slowest input: #{(slowest[0] * 1000).round(2)} ms, #{slowest[1]}"
      io.puts "total: #{(Time.instant - started).total_seconds.round(1)} s, peak GC heap #{peak_heap // (1024 * 1024)} MiB"
      io.puts "differential sample, every 10th input under 100 kB:"
      comparison.report(io, comparison.verdict_counts.values.sum)
    end
  end

  private def generate : {String, String}
    case @random.rand(100)
    when 0...55  then {"mutated", mutate(pick)}
    when 55...70 then {"spliced", splice}
    when 70...82 then {"nested", nested}
    when 82...90 then {"random-tokens", random_tokens}
    when 90...95 then {"long", long}
    else              {"binary", binary}
    end
  end

  private def pick : String
    @list_of_statements[@random.rand(@list_of_statements.size)]
  end

  private def mutate(sql : String) : String
    text = sql
    (1 + @random.rand(4)).times do
      break if text.empty?
      position = @random.rand(text.size + 1)
      text = case @random.rand(6)
             when 0 then text[0, position] + PIECES.sample(@random) + text[position..]
             when 1 then text[0, position] + " #{KEYWORDS.sample(@random)} " + text[position..]
             when 2 then text[0, position] + text[Math.min(text.size, position + 1 + @random.rand(12))..]
             when 3 then text[0, position] + text[position, 1 + @random.rand(40)] + text[position..]
             when 4 then text[0, position]
             else        text.byte_slice(0, Math.min(text.bytesize, position)) + (@random.rand(256).chr.to_s) + text[position..]
             end
    rescue ArgumentError | IndexError
      text = sql
    end
    text
  end

  private def splice : String
    first = pick
    second = pick
    first[0, @random.rand(first.size + 1)] + second[@random.rand(second.size + 1)..]
  end

  private def nested : String
    depth = 1 + @random.rand(3000)
    case @random.rand(6)
    when 0 then "SELECT " + "(" * depth + "1" + ")" * depth
    when 1 then "SELECT " + "NOT " * depth + "1"
    when 2 then "SELECT " + "- " * depth + "1"
    when 3 then "SELECT " + "(SELECT " * depth + "1" + ")" * depth
    when 4 then "SELECT " + "CASE WHEN 1 THEN " * depth + "1" + " END" * depth
    else        "SELECT " + "coalesce(" * depth + "1" + ")" * depth
    end
  end

  private def random_tokens : String
    String.build do |io|
      (1 + @random.rand(60)).times do
        io << (@random.rand(2) == 0 ? KEYWORDS.sample(@random) : PIECES.sample(@random)) << ' '
      end
    end
  end

  private def long : String
    case @random.rand(4)
    when 0 then "SELECT '" + "a" * (1 + @random.rand(1_100_000)) + "'"
    when 1 then "SELECT " + (["1"] * (1 + @random.rand(5000))).join(", ")
    when 2 then "SELECT 1" + " UNION ALL SELECT 1" * (1 + @random.rand(700))
    else        "SELECT " + (1..(1 + @random.rand(40_000))).join(" + ") { |number| "?#{number}" }
    end
  end

  private def binary : String
    bytes = Bytes.new(1 + @random.rand(400))
    @random.random_bytes(bytes)
    String.new(bytes)
  end
end

# Times parsing against C SQLite's prepare step.
class SQLParseBenchmark
  def initialize(@list_of_statements : Array(String), @rounds : Int32)
  end

  def run : String
    database = SQLiteSQLOracle.schema_database(@list_of_statements)
    usable = @list_of_statements.select do |sql|
      status = SQLiteSQLOracle::LibOracle.prepare_v2(database, sql, sql.bytesize, out statement, nil)
      SQLiteSQLOracle::LibOracle.finalize(statement) unless statement.null?
      status == 0 && !sql.lstrip.upcase.starts_with?("CREATE")
    end
    engine_times = [] of Float64
    c_times = [] of Float64
    @rounds.times do
      engine_times << timed { usable.each { |sql| SQL::Parser.parse(sql) } }
      c_times << timed do
        usable.each do |sql|
          SQLiteSQLOracle::LibOracle.prepare_v2(database, sql, sql.bytesize, out statement, nil)
          SQLiteSQLOracle::LibOracle.finalize(statement)
        end
      end
    end
    engine = median(engine_times)
    c = median(c_times)
    bytes = usable.sum(&.bytesize)
    ratio = engine < c ? "#{(c / engine).round(2)}x as fast as" : "#{(engine / c).round(2)}x slower than"
    String.build do |io|
      io.puts "C SQLite #{SQLiteSQLOracle.version}"
      io.puts "statements: #{usable.size} that C prepares on the corpus schema (CREATE excluded), #{bytes} bytes"
      io.puts "rounds: #{@rounds}, interleaved"
      io.puts "engine parse, median: #{(engine * 1000).round(2)} ms (#{(engine * 1e9 / usable.size).round} ns/statement)"
      io.puts "C prepare_v2 + finalize, median: #{(c * 1000).round(2)} ms (#{(c * 1e9 / usable.size).round} ns/statement)"
      io.puts "engine rounds ms: #{engine_times.map { |time| (time * 1000).round(2) }.join(", ")}"
      io.puts "C rounds ms: #{c_times.map { |time| (time * 1000).round(2) }.join(", ")}"
      io.puts "the engine's parser is #{ratio} C's prepare step"
    end
  end

  private def timed(&) : Float64
    started = Time.instant
    yield
    (Time.instant - started).total_seconds
  end

  private def median(values : Array(Float64)) : Float64
    sorted = values.sort
    middle = sorted.size // 2
    sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  end
end

mode = ARGV[0]? || abort "usage: sqlite_engine_sql_oracle.cr corpus|records FILE REPORT_DIR"
file = ARGV[1]? || abort "missing FILE"
report_directory = Path[ARGV[2]? || "."]
comparison = SQLOracleComparison.new
started = Time.instant

case mode
when "corpus"
  statements = File.read_lines(file)
  schema = SQLiteSQLOracle.schema_database(statements)
  statements.each_with_index(1) do |sql, line|
    source = "#{file}:#{line}"
    statement = comparison.compare(source, sql)
    next unless statement
    printed = comparison.check_printed(source, sql, statement)
    next unless printed
    if statement.is_a?(SQL::SelectStatement) || statement.is_a?(SQL::Insert) ||
       statement.is_a?(SQL::Update) || statement.is_a?(SQL::Delete)
      comparison.check_bytecode(schema, source, sql, printed)
    end
  end
  total = statements.size
when "records"
  total = 0
  seen = Set(String).new
  File.each_line(file) do |line|
    next if line.blank?
    record = SQLRecord.from_json(line)
    SQLiteSQLOracle.split_statements(record.sql).each do |sql|
      next unless seen.add?(sql)
      comparison.compare(record.source, sql)
      total += 1
    end
  end
when "fuzz", "bench"
  report_directory = Path[ARGV[4]? || ARGV[3]? || abort "missing REPORT_DIR"]
  Dir.mkdir_p(report_directory)
  summary = mode == "fuzz" ? SQLFuzzer.new(File.read_lines(file), ARGV[2].to_i, ARGV[3].to_u64).run(comparison, report_directory) : SQLParseBenchmark.new(File.read_lines(file), ARGV[2].to_i).run
  STDOUT.print summary
  File.write(report_directory / "summary.txt", summary)
  exit
else
  abort "unknown mode #{mode}"
end

summary = String.build { |io| comparison.report(io, total) }
summary += "elapsed: #{(Time.instant - started).total_seconds.round(1)} s\n"
STDOUT.print summary
comparison.write_details(report_directory)
File.write(report_directory / "summary.txt", summary)
