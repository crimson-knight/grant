# Compares the rows Grant's SQLite engine returns with C SQLite's.
#
#   crystal-alpha run scripts/sqlite_engine_query_differential.cr -- corpus CORPUS SEED BINDINGS REPORT_DIR
#     Every SELECT and WITH statement of the corpus, on a database holding a
#     schema in which C prepares it (corpus CREATE statements) filled with
#     seeded random rows, with BINDINGS seeded parameter bindings each.
#
#   crystal-alpha run scripts/sqlite_engine_query_differential.cr -- tests JSONL REPORT_DIR
#     SQLite's Tcl test statements, file by file in order on a database file:
#     C runs every statement; after each SELECT C completes, the engine runs
#     it on the same file.
#
#   crystal-alpha run scripts/sqlite_engine_query_differential.cr -- random SEED COUNT REPORT_DIR
#     COUNT generated queries over generated schemas and data.
#
# Rows compare typed (reals by IEEE 754 bits); in order where a top-level
# ORDER BY applies (rows the engine reports tied in any order among
# themselves), as multisets otherwise. With LIMIT and no ORDER BY, SQL
# leaves which rows come back open: the engine's rows count as correct when
# they are as many as C's and all among the rows C returns without the
# LIMIT. Errors compare by message. Results that differ only by a choice
# SQLite makes from its plan (which of several equal values a GROUP BY,
# DISTINCT, compound, min() or max() shows; whether a row that raises
# "integer overflow" is reached) are counted apart and listed in
# plan_choices.txt.
#
#   crystal-alpha run scripts/sqlite_engine_query_differential.cr -- query DATABASE SQL [PARAMETER...]
#     Prints both engines' rows for one statement (for a saved schema-N.db).
#
# Link a pinned libsqlite3 with --link-flags "-L DIR -Wl,-rpath,DIR".
require "file_utils"
require "json"
require "../spec/support/sqlite_engine/query_oracle"
require "./sqlite_engine_query_generator"

private alias SQL = Grant::SQLiteEngine::SQL
private alias Value = Grant::SQLiteEngine::Value
private alias Outcome = SQLiteQueryOracle::Outcome

record TestRecord, source : String, sql : String do
  include JSON::Serializable
end

# Counts and lists what a run found.
class DifferentialReport
  getter counts = Hash(String, Int64).new(0_i64)
  getter list_of_differences = [] of String
  getter skipped = Hash(String, Int64).new(0_i64)
  getter list_of_examples = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

  def count(key : String) : Nil
    @counts[key] += 1
  end

  def skip(reason : String, example : String) : Nil
    @skipped[reason] += 1
    list = @list_of_examples[reason]
    list << example if list.size < 5
  end

  getter list_of_representatives = [] of String

  # A result that matches C's once equal values (NOCASE, RTRIM, 0 and 0.0)
  # are treated alike, from a query that keeps one of several equal rows.
  def plan_choice(kind : Symbol, text : String) : Nil
    label = PLAN_CHOICE_LABELS[kind]
    @counts[label] += 1
    @list_of_representatives << text if @list_of_representatives.size < 1_000
  end

  PLAN_CHOICE_LABELS = {
    equal_values:     "rows differing only in which of several equal values is shown",
    evaluation_order: "integer overflow raised by one engine only (rows reached in plan order)",
    offset_by_match:  "C's OFFSET skipped one row per EXISTS match (its rows are not a window of its own full result)",
    summation_order:  "sum(), avg() or total() of reals equal to 12 digits (reals added in plan order)",
  }

  def difference(text : String) : Nil
    @counts["differences"] += 1
    @list_of_differences << text if @list_of_differences.size < 2_000
  end

  def write(directory : String, header : String) : Nil
    Dir.mkdir_p(directory)
    File.write(File.join(directory, "differences.txt"), @list_of_differences.join("\n\n") + "\n")
    File.write(File.join(directory, "plan_choices.txt"), @list_of_representatives.join("\n\n") + "\n")
    File.open(File.join(directory, "summary.txt"), "w") do |io|
      io.puts header
      io.puts "C SQLite #{SQLiteSQLOracle.version}"
      @counts.keys.sort!.each { |key| io.puts "#{key}: #{@counts[key]}" }
      io.puts "differences: #{@counts["differences"]}" unless @counts.has_key?("differences")
      unless @skipped.empty?
        io.puts "skipped, by reason:"
        @skipped.keys.sort!.each do |reason|
          io.puts "  #{reason}: #{@skipped[reason]}"
          @list_of_examples[reason].each { |example| io.puts "      e.g. #{example[0, 200].gsub('\n', ' ')}" }
        end
      end
    end
  end
end

module QueryDifferential
  # Compares one statement on both engines; returns the difference or nil.
  def self.compare(connection : SQLiteQueryOracle::Connection, session : Grant::SQLiteEngine::Query::Session,
                   sql : String, statement : SQL::SelectStatement, parameters : Array(Value)) : {String?, Outcome, Symbol?}
    expected = connection.query(sql, parameters)
    actual = SQLiteQueryOracle.engine_query(session, sql, parameters)
    ordered = !statement.order_by.empty?
    difference = SQLiteQueryOracle.difference(expected, actual, ordered)
    if difference && statement.limit && expected.error.nil? && actual.error.nil? &&
       expected.list_of_rows.size == actual.list_of_rows.size
      difference = nil if limit_choice_only?(connection, session, statement, parameters, actual)
    end
    # With LIMIT and no ORDER BY, which rows are read decides whether a row
    # that raises an error is reached; counted as SQL's choice when both
    # engines raise the same error without the LIMIT.
    if difference && statement.limit && statement.order_by.empty? && (expected.error.nil? != actual.error.nil?)
      unlimited = SQL::SelectStatement.new(statement.with_clause, statement.cores, statement.operators, statement.order_by, nil).to_sql
      full_expected = connection.query(unlimited, parameters)
      full_actual = SQLiteQueryOracle.engine_query(session, unlimited, parameters)
      difference = nil if full_expected.error && full_expected.error == full_actual.error
    end
    # abs() of the smallest integer and an integer sum() that overflows
    # raise "integer overflow" from inside a row; whether a query reaches
    # such a row before a filter drops it, and the order sum() adds in,
    # follow the plan (join order, index seeks, term order).
    if difference && [expected.error, actual.error].compact == ["integer overflow"]
      return {nil, expected, :evaluation_order}
    end
    # sum(), avg() and total() of reals add in the order the plan reads
    # rows (join order, index order), which moves the last bits.
    if difference && expected.error.nil? && actual.error.nil? && statement.to_sql =~ /\b(sum|avg|total)\(/i &&
       SQLiteQueryOracle.difference(rounded(expected), rounded(actual), ordered, folded: groups_rows?(statement)).nil?
      return {nil, expected, :summation_order}
    end
    if difference && expected.error.nil? && actual.error.nil? &&
       offset_counted_per_match?(connection, statement, parameters, expected, actual)
      return {nil, expected, :offset_by_match}
    end
    if difference && expected.error.nil? && actual.error.nil? && QueryDifferential.groups_rows?(statement) &&
       SQLiteQueryOracle.difference(expected, actual, ordered, folded: true).nil?
      return {nil, expected, :equal_values}
    end
    {difference, expected, nil}
  end

  # GROUP BY, DISTINCT and UNION/INTERSECT/EXCEPT keep one of several rows
  # that compare equal, and min(), max() and DISTINCT aggregates one of
  # several equal values; which one SQLite shows follows its plan (an
  # index or the sorter's order).
  def self.groups_rows?(statement : SQL::SelectStatement) : Bool
    return true if statement.to_sql =~ /\b(min|max)\(|\(DISTINCT /i
    return true if statement.operators.any? { |operator| !operator.union_all? }
    statement.cores.any? do |core|
      core.is_a?(SQL::SelectClause) && (core.distinct.distinct? || !core.group_by.empty?)
    end
  end

  # With LIMIT, the rows at the cut that tie under ORDER BY (or any rows,
  # without ORDER BY) are SQL's choice. True when both engines agree
  # without the LIMIT and the engine's limited rows are a slice of its own
  # unlimited result (in order, under ORDER BY).
  def self.limit_choice_only?(connection : SQLiteQueryOracle::Connection, session : Grant::SQLiteEngine::Query::Session,
                              statement : SQL::SelectStatement, parameters : Array(Value), actual : Outcome) : Bool
    unlimited = SQL::SelectStatement.new(statement.with_clause, statement.cores, statement.operators,
      statement.order_by, nil).to_sql
    ordered = !statement.order_by.empty?
    full_expected = connection.query(unlimited, parameters)
    full_actual = SQLiteQueryOracle.engine_query(session, unlimited, parameters)
    # Both raise the same error over every row; which rows a LIMIT returns
    # before reaching it follows the plan.
    return true if full_expected.error && full_expected.error == full_actual.error && !ordered
    folded = groups_rows?(statement)
    return false if SQLiteQueryOracle.difference(full_expected, full_actual, ordered, folded: folded)
    limited = actual.list_of_rows.map { |row| folded ? folded_row_token(row) : SQLiteQueryOracle.row_token(row) }
    full = full_actual.list_of_rows.map { |row| folded ? folded_row_token(row) : SQLiteQueryOracle.row_token(row) }
    if ordered
      return true if limited.empty?
      (0..(full.size - limited.size)).any? { |start| full[start, limited.size] == limited }
    else
      pool = full.tally
      limited.all? do |token|
        remaining = pool[token]? || 0
        pool[token] = remaining - 1
        remaining > 0
      end
    end
  end

  # *outcome* with each real rounded to 12 significant digits.
  def self.rounded(outcome : Outcome) : Outcome
    rows = outcome.list_of_rows.map do |row|
      row.map { |value| value.is_a?(Float64) && value.finite? ? ("%.12g" % value).to_f : value }
    end
    Outcome.new(outcome.list_of_column_names, rows, outcome.error, outcome.list_of_ties)
  end

  def self.folded_row_token(row : Array(Value)) : String
    row.map { |value| SQLiteQueryOracle.folded_token(value) }.join('|')
  end

  # C 3.51.0 runs a correlated EXISTS as a join and lets OFFSET skip one
  # row per matching inner row, so its rows under an OFFSET are not a
  # window of its own unlimited result. True when that is so and the
  # engine's rows are that window.
  def self.offset_counted_per_match?(connection : SQLiteQueryOracle::Connection, statement : SQL::SelectStatement,
                                     parameters : Array(Value), expected : Outcome, actual : Outcome) : Bool
    limit = statement.limit
    return false unless limit && statement.to_sql.includes?("EXISTS")
    count = limit.count
    offset = limit.offset
    return false unless offset
    bounds_sql = "SELECT CAST((#{count.to_sql}) AS INTEGER), CAST((#{offset.to_sql}) AS INTEGER)"
    return false if bounds_sql.includes?('?')
    bounds = connection.query(bounds_sql, [] of Value).list_of_rows.first?
    return false unless bounds && (rows_wanted = bounds[0]).is_a?(Int64) && (skipped = bounds[1]).is_a?(Int64)
    unlimited = SQL::SelectStatement.new(statement.with_clause, statement.cores, statement.operators, statement.order_by, nil).to_sql
    full = connection.query(unlimited, parameters).list_of_rows.map { |row| SQLiteQueryOracle.row_token(row) }
    start = skipped.clamp(0_i64, full.size.to_i64).to_i
    window = rows_wanted < 0 ? full[start..] : full[start, rows_wanted.to_i]
    c_rows = expected.list_of_rows.map { |row| SQLiteQueryOracle.row_token(row) }
    engine_rows = actual.list_of_rows.map { |row| SQLiteQueryOracle.row_token(row) }
    c_rows.tally != window.tally && engine_rows.tally == window.tally
  end

  def self.describe(sql : String, parameters : Array(Value), difference : String) : String
    "sql: #{sql}\n  parameters: #{parameters.map { |value| SQLiteQueryOracle.token(value) }.join(", ")}\n  #{difference}"
  end
end

# ------------------------------------------------------------------ corpus

class CorpusDifferential
  @list_of_creates = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
  @list_of_indexes = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
  @list_of_selects = [] of {String, SQL::SelectStatement}

  def initialize(@corpus : String, @seed : Int64, @bindings : Int32, @report : DifferentialReport, @work : String)
  end

  def run : Nil
    File.each_line(@corpus) do |line|
      sql = line.strip
      next if sql.empty?
      statement = begin
        SQL::Parser.parse(sql)
      rescue SQL::ParseError
        next
      end
      case statement
      when SQL::CreateTable
        @list_of_creates[statement.name.value.downcase] << sql unless statement.temporary || statement.schema
      when SQL::CreateIndex
        @list_of_indexes[statement.table.value.downcase] << sql
      when SQL::SelectStatement
        @list_of_selects << {sql, statement}
      end
    end
    groups = Hash(Array(String), Array({String, SQL::SelectStatement})).new { |hash, key| hash[key] = [] of {String, SQL::SelectStatement} }
    @list_of_selects.each do |entry|
      sql, statement = entry
      @report.count("select statements")
      if schema = schema_for(sql, statement)
        groups[schema] << entry
      else
        @report.skip("C prepares it on no corpus schema", sql)
      end
    end
    groups.each_with_index do |(schema, entries), group_index|
      run_group(schema, entries, group_index)
    end
  end

  # The tables a statement names, from every FROM clause in it.
  private def tables_of(statement : SQL::SelectStatement, into : Set(String) = Set(String).new) : Set(String)
    statement.with_clause.try(&.tables.each { |table| tables_of(table.query, into) })
    statement.cores.each do |core|
      next unless core.is_a?(SQL::SelectClause)
      if from = core.from
        from.items.each { |item| tables_of_source(item.source, into) }
      end
      [core.where, core.having].compact.each { |expression| tables_of_expression(expression, into) }
      core.columns.each { |column| tables_of_expression(column.expression, into) if column.is_a?(SQL::ExpressionColumn) }
    end
    into
  end

  private def tables_of_source(source : SQL::TableSource, into : Set(String)) : Nil
    case source
    when SQL::TableReference then into << source.name.value.downcase
    when SQL::SubquerySource then tables_of(source.query, into)
    when SQL::NestedJoin     then source.from.items.each { |item| tables_of_source(item.source, into) }
    end
  end

  private def tables_of_expression(expression : SQL::Expression, into : Set(String)) : Nil
    case expression
    when SQL::Exists, SQL::ScalarSubquery then tables_of(expression.query, into)
    when SQL::InSelect
      tables_of(expression.query, into)
      tables_of_expression(expression.operand, into)
    else
      SQLDifferentialWalk.children(expression).each { |child| tables_of_expression(child, into) }
    end
  end

  # The CREATE statements of a schema in which C prepares *sql*: the first
  # definition of each table it names, then other definitions until one
  # prepares.
  private def schema_for(sql : String, statement : SQL::SelectStatement) : Array(String)?
    names = tables_of(statement).select { |name| @list_of_creates.has_key?(name) }.to_a.sort
    choices = names.map { |name| @list_of_creates[name].uniq }
    combination = choices.map(&.first)
    return combination if prepares?(sql, combination)
    tried = 0
    # Vary one table at a time, then all combinations up to a bound.
    choices.each_with_index do |options, position|
      options.each do |option|
        candidate = combination.dup
        candidate[position] = option
        return candidate if prepares?(sql, candidate)
      end
    end
    each_combination(choices) do |candidate|
      tried += 1
      return candidate if prepares?(sql, candidate)
      break if tried > 256
    end
    nil
  end

  private def each_combination(choices : Array(Array(String)), & : Array(String) ->) : Nil
    indexes = Array(Int32).new(choices.size, 0)
    loop do
      yield indexes.map_with_index { |index, position| choices[position][index] }
      position = 0
      while position < choices.size
        indexes[position] += 1
        break if indexes[position] < choices[position].size
        indexes[position] = 0
        position += 1
      end
      break if position == choices.size
    end
  end

  private def prepares?(sql : String, creates : Array(String)) : Bool
    connection = SQLiteQueryOracle::Connection.new(":memory:")
    creates.each { |create| connection.exec(create) }
    !connection.parameter_count(sql).nil?
  ensure
    connection.try &.close
  end

  private def run_group(schema : Array(String), entries : Array({String, SQL::SelectStatement}), group_index : Int32) : Nil
    path = File.join(@work, "corpus-#{group_index}.db")
    File.delete(path) if File.exists?(path)
    connection = SQLiteQueryOracle::Connection.new(path)
    random = Random.new(@seed &+ group_index)
    pool = [] of Value
    schema.each do |create|
      connection.exec(create)
      statement = SQL::Parser.parse(create)
      raise "generated schema is not CREATE TABLE: #{create}" unless statement.is_a?(SQL::CreateTable)
      @list_of_indexes[statement.name.value.downcase].each { |index| connection.exec(index) }
      fill(connection, statement, random, pool)
    end
    database = Grant::SQLiteEngine::Database.open(path)
    session = Grant::SQLiteEngine::Query::Session.new(database)
    entries.each do |(sql, statement)|
      count = connection.parameter_count(sql) || 0
      bindings = count == 0 ? 1 : @bindings
      bindings.times do
        parameters = Array(Value).new(count) { pick(random, pool) }
        @report.count("executions")
        begin
          difference, expected, representative = QueryDifferential.compare(connection, session, sql, statement, parameters)
          @report.plan_choice(representative, QueryDifferential.describe(sql, parameters, representative.to_s)) if representative
          @report.count(expected.error ? "executions where C raised an error" : "executions where C returned rows")
          @counts_rows += expected.list_of_rows.size
          if difference
            @report.difference(QueryDifferential.describe(sql, parameters, difference))
          end
        rescue error : Grant::SQLiteEngine::UnsupportedSQL
          @report.difference(QueryDifferential.describe(sql, parameters, "engine: #{error.message}"))
          break
        rescue error : Exception
          @report.difference(QueryDifferential.describe(sql, parameters, "engine raised #{error.class}: #{error.message}"))
          break
        end
      end
    end
    @report.counts["rows compared"] = @counts_rows
    database.close
    connection.close
    File.delete(path) if File.exists?(path)
  end

  @counts_rows = 0_i64

  WORDS = ["alpha", "Alpha", "ALPHA", "beta", "gamma", "", " padded ", "x", "10", "3.5", "abc%", "a_b", "Zed", "élan", "draft", "published", "archived", "Region North", "north"]
  TIMES = ["2026-11-01 10:00:00.000000", "2026-11-02 11:30:00.123456", "2026-10-30 09:15:00.000000", "2026-11-03 00:00:00.000000", "2025-01-01 00:00:00.000000"]

  # Inserts 0 to 24 random rows into the table; values follow each
  # column's declared type, with NULLs, duplicates and some wrong types.
  private def fill(connection : SQLiteQueryOracle::Connection, statement : SQL::CreateTable, random : Random, pool : Array(Value)) : Nil
    columns = statement.columns
    return if columns.empty?
    names = columns.map { |column| %("#{column.name.value.gsub('"', "\"\"")}") }.join(", ")
    marks = (["?"] * columns.size).join(", ")
    sql = %(INSERT OR IGNORE INTO "#{statement.name.value.gsub('"', "\"\"")}" (#{names}) VALUES (#{marks}))
    rows = random.rand(0..24)
    rows.times do |row_index|
      values = columns.map do |column|
        not_null = column.constraints.any?(SQL::NotNullConstraint)
        value = random_value(column, random, row_index)
        value = random_value(column, random, row_index) if value.nil? && not_null
        value = 0_i64 if value.nil? && not_null
        value
      end
      connection.query(sql, values)
      values.each { |value| pool << value if pool.size < 4_000 && random.rand(3) == 0 }
    end
  end

  private def random_value(column : SQL::ColumnDefinition, random : Random, row_index : Int32) : Value
    type_name = column.type_name.try(&.words.map(&.value).join(' ').upcase) || ""
    return if random.rand(10) == 0
    roll = random.rand(20)
    if type_name.includes?("INT")
      return WORDS.sample(random) if roll == 0
      return (row_index + 1).to_i64 if column.constraints.any?(SQL::PrimaryKeyColumnConstraint) && roll < 15
      random.rand(-2..12).to_i64
    elsif type_name.includes?("BOOL")
      roll == 0 ? "t" : random.rand(2).to_i64
    elsif type_name.includes?("CHAR") || type_name.includes?("TEXT") || type_name.includes?("CLOB")
      return random.rand(-3..12).to_i64 if roll == 0
      WORDS.sample(random)
    elsif type_name.includes?("DATE") || type_name.includes?("TIME")
      TIMES.sample(random)
    elsif type_name.includes?("REAL") || type_name.includes?("FLOA") || type_name.includes?("DOUB")
      return random.rand(-5..20).to_i64 if roll < 4
      (random.rand(-2000..2000) / 8.0).to_f64
    elsif type_name.includes?("BLOB")
      Random.new(row_index).random_bytes(random.rand(0..6))
    elsif type_name.empty?
      case roll % 4
      when 0 then random.rand(-2..12).to_i64
      when 1 then WORDS.sample(random)
      when 2 then (random.rand(-80..80) / 4.0).to_f64
      else        Random.new(row_index).random_bytes(3)
      end
    else
      # NUMERIC, DECIMAL, JSON and the rest.
      case roll % 5
      when 0 then "#{random.rand(0..9)}.#{random.rand(0..99)}"
      when 1 then WORDS.sample(random)
      when 2 then (random.rand(-80..80) / 4.0).to_f64
      else        random.rand(-2..12).to_i64
      end
    end
  end

  private def pick(random : Random, pool : Array(Value)) : Value
    roll = random.rand(10)
    return pool.sample(random) if roll < 7 && !pool.empty?
    [nil, 0_i64, 1_i64, 2_i64, 5_i64, -1_i64, "1", "alpha", 2.5, "2026-11-02 00:00:00.000000", Bytes[1, 2]].sample(random).as(Value)
  end
end

module SQLDifferentialWalk
  extend Grant::SQLiteEngine::Query::ExpressionCompiler

  def self.children(expression : SQL::Expression) : Array(SQL::Expression)
    children_of(expression)
  end
end

# ------------------------------------------------------------------- tests

class TestsDifferential
  # PRAGMAs that change how C runs later statements in ways the engine does
  # not model; a file stops being compared once it sets one.
  SEMANTIC_PRAGMAS = %w[case_sensitive_like reverse_unordered_selects short_column_names full_column_names
    legacy_file_format encoding automatic_index query_only trusted_schema writable_schema]

  # The most scratch one run may use; past it the run stops with an error.
  SCRATCH_LIMIT_BYTES = 2_i64 * 1024 * 1024 * 1024

  getter peak_scratch_bytes = 0_i64

  # Functions that read the connection's write counters, which count C's
  # writes here, not the engine's.
  CONNECTION_COUNTERS = /\b(last_insert_rowid|changes|total_changes)\s*\(/i

  def initialize(@records_path : String, @report : DifferentialReport, @work : String)
  end

  def run : Nil
    files = [] of {String, Array(String)}
    current = nil
    File.each_line(@records_path) do |line|
      record = TestRecord.from_json(line)
      file = record.source.split(':').first
      if current.nil? || current[0] != file
        current = {file, [] of String}
        files << current
      end
      current[1] << record.sql
    end
    # Relative names a test ATTACHes or opens land in the scratch folder.
    Dir.cd(@work) do
      files.each { |(file, blocks)| run_file(file, blocks) }
    end
  end

  # Empties the scratch folder, so each test file starts from nothing and
  # leaves nothing behind.
  private def clear_scratch : Nil
    Dir.children(@work).each do |name|
      entry = File.join(@work, name)
      File.directory?(entry) ? FileUtils.rm_rf(entry) : File.delete(entry)
    end
  end

  # Records the scratch folder's size and stops the run past the limit.
  private def check_scratch(file : String) : Nil
    total = 0_i64
    Dir.children(@work).each do |name|
      entry = File.join(@work, name)
      total += File.size(entry).to_i64 if File.file?(entry)
    end
    @peak_scratch_bytes = total if total > @peak_scratch_bytes
    if total > SCRATCH_LIMIT_BYTES
      raise "scratch #{total} bytes passed the #{SCRATCH_LIMIT_BYTES}-byte limit in #{file}"
    end
  end

  private def run_file(file : String, blocks : Array(String)) : Nil
    clear_scratch
    STDERR.puts "tests: #{file}"
    STDERR.flush
    path = File.join(@work, "tests.db")
    connection = SQLiteQueryOracle::Connection.new(path)
    # Bounds what one test file can build: 256 MB of 4 KB pages in the main
    # file, temporary tables and sorts in memory, 2 GB of heap.
    connection.exec("PRAGMA max_page_count = 65536")
    connection.exec("PRAGMA temp_store = MEMORY")
    connection.exec("PRAGMA hard_heap_limit = 2147483648")
    StatementDeadline.install(connection)
    stopped = nil
    blocks.each do |block|
      SQLiteSQLOracle.split_statements(block).each do |sql|
        @report.count("statements")
        check_scratch(file)
        StatementDeadline.start
        statement = begin
          SQL::Parser.parse(sql)
        rescue SQL::ParseError
          connection.exec(sql)
          next
        end
        if statement.is_a?(SQL::Pragma) && SEMANTIC_PRAGMAS.includes?(statement.name.value.downcase)
          stopped ||= "file set PRAGMA #{statement.name.value}"
        end
        if statement.is_a?(SQL::Attach) || (statement.is_a?(SQL::CreateTable) && statement.temporary) ||
           (statement.is_a?(SQL::CreateView) && statement.temporary)
          stopped ||= "file uses attached or temporary schemas"
        end
        unless statement.is_a?(SQL::SelectStatement)
          connection.exec(sql)
          next
        end
        @report.count("select statements")
        if reason = stopped
          connection.query(sql)
          @report.skip(reason, "#{file}: #{sql}")
          next
        end
        unless SQLiteQueryOracle::LibAutocommit.get_autocommit(connection.handle) != 0
          connection.query(sql)
          @report.skip("inside a transaction C has open", "#{file}: #{sql}")
          next
        end
        compare(connection, path, file, sql, statement)
      end
    end
    connection.close
    check_scratch(file)
    clear_scratch
  end

  # PACKET_05 item 9 counts these apart: virtual table modules (FTS and
  # the like, which this build of C lacks too), rows made by random() and
  # randomblob(), and out-of-memory and size-limit cases.
  def self.out_of_scope(sql : String, expected : SQLiteQueryOracle::Outcome, actual : SQLiteQueryOracle::Outcome) : String?
    errors = [expected.error, actual.error].compact
    if errors.any?(&.starts_with?("no such module: "))
      return "out of scope: a virtual table module"
    end
    if expected.error.nil? && actual.error.nil? && RANDOM_FUNCTIONS.matches?(sql)
      return "out of scope: rows made by random() or randomblob()"
    end
    if errors.any? { |message| SIZE_LIMITS.matches?(message) }
      return "out of scope: out of memory or a size limit"
    end
    nil
  end

  # The temp schema belongs to a connection: objects C's connection made
  # there (CREATE VIEW temp.v, CREATE TEMP TRIGGER) are not in the file,
  # so the engine's fresh session cannot see them. A difference is counted
  # apart when the engine reports no such table for a temp schema table
  # or for a name C holds in its temp schema, or when the statement reads
  # the temp schema table while C's temp schema holds objects.
  TEMP_SCHEMA_NAMES  = {"sqlite_temp_master", "sqlite_temp_schema", "temp.sqlite_master", "temp.sqlite_schema"}
  TEMP_SCHEMA_READ   = /\b(sqlite_temp_master|sqlite_temp_schema|temp\s*\.\s*sqlite_(master|schema))\b/i
  TEMP_SCHEMA_REASON = "out of scope: an object of the C connection's own temp schema"

  def self.temp_schema(connection : SQLiteQueryOracle::Connection, sql : String, actual : SQLiteQueryOracle::Outcome) : String?
    message = actual.error
    unless message && message.starts_with?("no such table: ")
      return unless TEMP_SCHEMA_READ.matches?(sql)
      objects = connection.query("SELECT 1 FROM sqlite_temp_schema LIMIT 1")
      return objects.list_of_rows.empty? ? nil : TEMP_SCHEMA_REASON
    end
    name = message.lchop("no such table: ").downcase
    return TEMP_SCHEMA_REASON if TEMP_SCHEMA_NAMES.includes?(name) || name.starts_with?("temp.")
    temp = connection.query("SELECT 1 FROM sqlite_temp_schema WHERE lower(name) = ?", [name] of SQLiteQueryOracle::Value)
    temp.list_of_rows.empty? ? nil : TEMP_SCHEMA_REASON
  end

  RANDOM_FUNCTIONS = /\b(random|randomblob)\s*\(/i
  SIZE_LIMITS      = /\A(out of memory|string or blob too big|too many columns in result set|too many references to|too many FROM clause terms)/

  private def compare(connection : SQLiteQueryOracle::Connection, path : String, file : String, sql : String,
                      statement : SQL::SelectStatement) : Nil
    expected = connection.query(sql, row_limit: 20_000)
    if CONNECTION_COUNTERS.matches?(sql)
      @report.skip("reads the counters of writes C made (changes, last_insert_rowid; G4b)", "#{file}: #{sql}")
      return
    end
    if expected.error == "interrupted"
      @report.skip("C ran past #{StatementDeadline::LIMIT.total_seconds.to_i} s (an unbounded query)", "#{file}: #{sql}")
      return
    end
    if expected.error
      @report.count("selects C rejected")
    end
    unless File.exists?(path) && File.size(path) > 0
      @report.skip("database file not written yet", "#{file}: #{sql}")
      return
    end
    database = Grant::SQLiteEngine::Database.open(path)
    begin
      session = Grant::SQLiteEngine::Query::Session.new(database)
      session.progress_handler(10_000) { StatementDeadline.passed? }
      StatementDeadline.start
      actual = SQLiteQueryOracle.engine_query(session, sql, row_limit: 20_000)
      if actual.error == "interrupted"
        @report.skip("engine ran past #{StatementDeadline::LIMIT.total_seconds.to_i} s (C reorders the joins)", "#{file}: #{sql}")
        return
      end
      ordered = !statement.order_by.empty?
      difference = SQLiteQueryOracle.difference(expected, actual, ordered)
      if difference && statement.limit && !ordered && expected.error.nil? && actual.error.nil? &&
         expected.list_of_rows.size == actual.list_of_rows.size
        @report.skip("LIMIT without ORDER BY (rows SQL leaves open)", "#{file}: #{sql}")
        return
      end
      if difference && (reason = TestsDifferential.out_of_scope(sql, expected, actual) || TestsDifferential.temp_schema(connection, sql, actual))
        @report.skip(reason, "#{file}: #{sql}")
        return
      end
      if difference
        if expected.error && actual.error
          @report.count("both raised errors, messages differ")
        end
        @report.difference("#{file}\n" + QueryDifferential.describe(sql, [] of Value, difference))
      else
        @report.count("selects matching C")
      end
    rescue error : Grant::SQLiteEngine::UnsupportedSQL
      @report.skip("outside G4a: #{error.construct.split(':').first[0, 60]}", "#{file}: #{sql}")
    rescue error : Exception
      @report.difference("#{file}\n" + QueryDifferential.describe(sql, [] of Value, "engine raised #{error.class}: #{error.message}"))
    ensure
      database.close
    end
  end
end

module SQLiteQueryOracle
  @[Link("sqlite3")]
  lib LibAutocommit
    fun get_autocommit = sqlite3_get_autocommit(database : SQLiteSQLOracle::LibOracle::Database) : Int32
    fun progress_handler = sqlite3_progress_handler(database : SQLiteSQLOracle::LibOracle::Database, instructions : Int32,
                                                    callback : Void* -> Int32, argument : Void*) : Void
  end
end

# A time limit for each statement C runs in the tests mode: some test
# files run unbounded queries that the Tcl suite stops with its own
# progress handler.
module StatementDeadline
  LIMIT = 10.seconds

  @@ends_at = Time.instant

  def self.start : Nil
    @@ends_at = Time.instant + LIMIT
  end

  def self.passed? : Bool
    Time.instant > @@ends_at
  end

  def self.install(connection : SQLiteQueryOracle::Connection) : Nil
    SQLiteQueryOracle::LibAutocommit.progress_handler(connection.handle, 10_000,
      ->(_argument : Void*) { StatementDeadline.passed? ? 1 : 0 }, Pointer(Void).null)
  end
end

# ------------------------------------------------------------------ random

class RandomDifferential
  @kept = Set(Int32).new

  def initialize(@seed : Int64, @count : Int32, @report : DifferentialReport, @work : String, @directory : String)
  end

  # Copies the database of a schema with a difference into the report, for
  # the query mode to rerun.
  private def keep(path : String, schema_index : Int32) : Nil
    return if @kept.includes?(schema_index) || @kept.size >= 40
    @kept << schema_index
    Dir.mkdir_p(@directory)
    File.copy(path, File.join(@directory, "schema-#{schema_index}.db"))
  end

  def run : Nil
    generator = SQLiteQueryGenerator.new(@seed)
    path = File.join(@work, "random.db")
    queries_per_schema = 2_000
    schemas = (@count + queries_per_schema - 1) // queries_per_schema
    schemas.times do |schema_index|
      File.delete(path) if File.exists?(path)
      connection = SQLiteQueryOracle::Connection.new(path)
      generator.new_schema.each { |sql| connection.exec(sql) }
      database = Grant::SQLiteEngine::Database.open(path)
      session = Grant::SQLiteEngine::Query::Session.new(database)
      Math.min(queries_per_schema, @count - schema_index * queries_per_schema).times do
        sql, parameters = generator.query
        @report.count("queries")
        statement = begin
          SQL::Parser.parse(sql)
        rescue error : SQL::ParseError
          if connection.parameter_count(sql)
            @report.difference(QueryDifferential.describe(sql, parameters, "engine parser rejected it: #{error.message}"))
          else
            @report.skip("generated SQL neither parser accepts", sql)
          end
          next
        end
        unless statement.is_a?(SQL::SelectStatement)
          @report.skip("generated SQL that is not a SELECT", sql)
          next
        end
        begin
          difference, expected, representative = QueryDifferential.compare(connection, session, sql, statement, parameters)
          @report.plan_choice(representative, QueryDifferential.describe(sql, parameters, representative.to_s)) if representative
          @report.count(expected.error ? "queries C rejected" : "queries C answered")
          if difference
            @report.difference(QueryDifferential.describe(sql, parameters, difference) + "\n  schema: #{schema_index}")
            keep(path, schema_index)
          end
        rescue error : Exception
          @report.difference(QueryDifferential.describe(sql, parameters, "engine raised #{error.class}: #{error.message}"))
        end
      end
      database.close
      connection.close
    end
  end
end

mode = ARGV[0]? || abort "usage: corpus|tests|random ..."
report = DifferentialReport.new
work = File.join(Dir.tempdir, "grant-query-differential-#{Process.pid}")
Dir.mkdir_p(work)
at_exit { FileUtils.rm_rf(work) }
started = Time.instant
case mode
when "corpus"
  corpus, seed, bindings, directory = ARGV[1], ARGV[2].to_i64, ARGV[3].to_i, ARGV[4]
  CorpusDifferential.new(corpus, seed, bindings, report, work).run
  report.write(directory, "corpus #{corpus} seed #{seed} bindings #{bindings}, #{(Time.instant - started).total_seconds.round(1)} s")
when "tests"
  records, directory = ARGV[1], ARGV[2]
  tests = TestsDifferential.new(records, report, work)
  tests.run
  report.write(directory, "tests #{records}, #{(Time.instant - started).total_seconds.round(1)} s, peak scratch #{(tests.peak_scratch_bytes / 1_048_576).round(1)} MB")
when "random"
  seed, count, directory = ARGV[1].to_i64, ARGV[2].to_i, ARGV[3]
  RandomDifferential.new(seed, count, report, work, directory).run
  report.write(directory, "random seed #{seed} queries #{count}, #{(Time.instant - started).total_seconds.round(1)} s")
when "query"
  # query DATABASE SQL [PARAMETER...]: both engines' full results.
  path, sql = ARGV[1], ARGV[2]
  parameters = ARGV[3..].map { |text| text == "NULL" ? nil : (text.to_i64? || text.to_f? || text).as(Value) }
  connection = SQLiteQueryOracle::Connection.new(path)
  expected = connection.query(sql, parameters)
  session = Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.open(path))
  actual = SQLiteQueryOracle.engine_query(session, sql, parameters)
  {"C" => expected, "engine" => actual}.each do |name, outcome|
    puts "#{name}: #{outcome.list_of_column_names} error=#{outcome.error.inspect}"
    outcome.list_of_rows.each_with_index { |row, index| puts "  #{outcome.list_of_ties[index]? ? "=" : " "} #{SQLiteQueryOracle.row_token(row)}" }
  end
  exit
else
  abort "unknown mode #{mode}"
end
puts File.read(File.join(ARGV.last, "summary.txt"))
