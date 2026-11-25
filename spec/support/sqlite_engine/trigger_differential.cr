require "json"
require "file_utils"
require "./write_oracle"

# The trigger differential of scripts/sqlite_engine_trigger_differential.cr
# and spec/grant/sqlite_engine/query/triggers_spec.cr: scenarios of
# statements run on C SQLite and on Grant's engine, each on its own file,
# compared statement by statement and file by file.
record TriggerRecord, source : String, sql : String do
  include JSON::Serializable
end

# One named sequence of statements run on a fresh pair of files.
record TriggerScenario, name : String, list_of_statements : Array(String)

class TriggerReport
  getter counts = Hash(String, Int64).new(0_i64)
  getter list_of_differences = [] of String
  getter list_of_unexpressed = [] of String

  def count(key : String, amount : Int64 = 1_i64) : Nil
    @counts[key] += amount
  end

  def difference(text : String) : Nil
    count("differences")
    @list_of_differences << text
  end

  def unexpressed(text : String) : Nil
    count("statements the engine cannot express")
    @list_of_unexpressed << text
  end

  def write(directory : String, title : String) : Nil
    Dir.mkdir_p(directory)
    count("differences", 0_i64)
    File.write(File.join(directory, "differences.txt"), @list_of_differences.join("\n\n"))
    File.write(File.join(directory, "unexpressed.txt"), @list_of_unexpressed.join("\n\n"))
    summary = String.build do |io|
      io << title << '\n'
      io << "C SQLite " << String.new(SQLiteSQLOracle::LibOracle.libversion) << ' ' << String.new(SQLiteSQLOracle::LibOracle.sourceid) << '\n'
      @counts.keys.sort!.each { |key| io << key << ": " << @counts[key] << '\n' }
    end
    File.write(File.join(directory, "summary.txt"), summary)
    puts summary
  end
end

class TriggerDifferential
  # Objects only C created, because the engine could not express the
  # statement that makes them (a TEMP view): a later statement that
  # differs because it names one is listed with them.
  @list_of_skipped_names = [] of String
  @swapped = false

  def initialize(@report : TriggerReport, @work : String)
  end

  def run(scenario : TriggerScenario) : Nil
    @report.count("scenarios")
    directory = File.join(@work, "scenario")
    pair = SQLiteWriteOracle::Pair.new(directory, "trigger")
    @list_of_skipped_names.clear
    @swapped = false
    trace = [] of String
    traced = false
    begin
      scenario.list_of_statements.each do |sql|
        if sql.strip == "-- swap"
          swap(pair)
          trace << "-- swap"
          next
        end
        trace << sql
        before = @report.list_of_differences.size
        step(pair, scenario.name, sql)
        if !traced && @report.list_of_differences.size > before
          traced = true
          @report.list_of_differences[-1] += "\n  statements of the scenario so far:\n" + trace.last(40).map { |line| "    #{line}" }.join('\n')
        end
      end
      pair.c_step("ROLLBACK") unless pair.autocommit?
      pair.engine_step("ROLLBACK") if pair.session.in_transaction?
      # A swap opens a new session, which has no TEMP schema.
      if @swapped
        @report.count("TEMP schema comparisons skipped after a swap")
      else
        compare_temp_schema(pair, scenario.name)
      end
      compare_files(pair, scenario.name, "the end")
    ensure
      pair.close
      FileUtils.rm_rf(directory)
    end
  end

  private def step(pair : SQLiteWriteOracle::Pair, name : String, sql : String) : Nil
    if comment_only?(sql)
      @report.count("comment-only blocks skipped")
      return
    end
    @report.count("statements")
    expected = pair.c_step(attached_file(sql, pair, "c"))
    actual = begin
      pair.engine_step(attached_file(sql, pair, "engine"))
    rescue error : Grant::SQLiteEngine::UnsupportedSQL
      record_unexpressed(pair, name, sql, expected, error)
      return
    end
    @report.count("C errors") if expected.outcome.error
    @report.count("rows compared", expected.outcome.list_of_rows.size.to_i64)
    if difference = SQLiteWriteOracle::Pair.difference(expected, actual, ordered?(sql), pair.changes_in_step?, pair.rowid_in_step?)
      record_difference(pair, name, sql, expected, actual, difference)
      return
    end
    record_match(pair, name, sql, expected)
  end

  # A statement the engine cannot express: C's result becomes the state
  # both sides continue from.
  private def record_unexpressed(pair : SQLiteWriteOracle::Pair, name : String, sql : String, expected : SQLiteWriteOracle::StepResult, error : Exception) : Nil
    @report.unexpressed("#{name}\n  #{sql.strip}\n  engine: #{error.message}\n  C: #{expected.outcome.error || "ok"}")
    created_name(sql).try { |created| @list_of_skipped_names << created }
    swap(pair) if idle?(pair)
  end

  # A difference that names an object only C could create is downstream
  # of an unexpressed statement; any other difference is reported.
  private def record_difference(pair : SQLiteWriteOracle::Pair, name : String, sql : String, expected : SQLiteWriteOracle::StepResult, actual : SQLiteWriteOracle::StepResult, difference : String) : Nil
    texts = [sql, expected.outcome.error || "", actual.outcome.error || ""]
    skipped = @list_of_skipped_names.find { |skipped_name| texts.any? { |text| mentions?(text, skipped_name) } }
    unless skipped
      @report.difference("#{name}\n  #{sql.strip}\n  #{difference}")
      return
    end
    @report.unexpressed("#{name}\n  #{sql.strip}\n  downstream of #{skipped}, which only C could create\n  #{difference}")
    created_name(sql).try { |created| @list_of_skipped_names << created }
    swap(pair) if expected.outcome.error.nil? && idle?(pair)
  end

  private def record_match(pair : SQLiteWriteOracle::Pair, name : String, sql : String, expected : SQLiteWriteOracle::StepResult) : Nil
    @report.count("statements matching C")
    if expected.outcome.error.nil?
      word = first_word(sql)
      pair.changes_in_step = true if word.in?("INSERT", "REPLACE", "UPDATE", "DELETE", "WITH")
      pair.rowid_in_step = true if word.in?("INSERT", "REPLACE")
    end
    compare_files(pair, name, sql.strip) if schema_change?(sql) && idle?(pair)
  end

  private def idle?(pair : SQLiteWriteOracle::Pair) : Bool
    pair.autocommit? && !pair.session.in_transaction?
  end

  # An ATTACH of a file by name gets a file of its own for each side, in
  # the scenario directory, so C and the engine never share one.
  private def attached_file(sql : String, pair : SQLiteWriteOracle::Pair, side : String) : String
    return sql unless first_word(sql) == "ATTACH"
    open = sql.index('\'') || return sql
    close = sql.index('\'', open + 1) || return sql
    file = sql[open + 1...close]
    return sql if file.empty? || file == ":memory:" || file.starts_with?("file:")
    path = File.join(File.dirname(pair.c_path), "#{side}-#{File.basename(file)}")
    "#{sql[0, open + 1]}#{path}#{sql[close..]}"
  end

  private def comment_only?(sql : String) : Bool
    Grant::SQLiteEngine::SQL::Tokenizer.new(sql).next_token.kind.end_of_input?
  end

  # The object a CREATE statement makes, or nil.
  private def created_name(sql : String) : String?
    statement = Grant::SQLiteEngine::SQL::Parser.parse(sql)
    case statement
    when Grant::SQLiteEngine::SQL::CreateTable, Grant::SQLiteEngine::SQL::CreateView,
         Grant::SQLiteEngine::SQL::CreateIndex, Grant::SQLiteEngine::SQL::CreateTrigger
      statement.name.value
    end
  rescue Grant::SQLiteEngine::SQL::ParseError
    nil
  end

  # True when a word of *text* is *name* (case-insensitive).
  private def mentions?(text : String, name : String) : Bool
    tokenizer = Grant::SQLiteEngine::SQL::Tokenizer.new(text)
    loop do
      token = tokenizer.next_token
      return false if token.kind.end_of_input?
      word = tokenizer.text(token)
      word = word[1, word.size - 2] if word.size > 2 && word[0].in?('"', '`', '[')
      return true if word.compare(name, case_insensitive: true) == 0
    end
  end

  # The engine's file becomes a copy of C's.
  private def swap(pair : SQLiteWriteOracle::Pair) : Nil
    pair.copy_c_file_to_engine
    @swapped = true
    @report.count("engine files copied from C")
  end

  private def compare_files(pair : SQLiteWriteOracle::Pair, name : String, moment : String) : Nil
    @report.count("file comparisons")
    if difference = pair.file_difference
      @report.difference("#{name}\n  files after #{moment}\n  #{difference}")
    end
  end

  private def compare_temp_schema(pair : SQLiteWriteOracle::Pair, name : String) : Nil
    sql = "SELECT type, name, tbl_name, sql FROM sqlite_temp_master ORDER BY type, name"
    expected = pair.c_step(sql)
    actual = pair.engine_step(sql)
    @report.count("temp schema comparisons")
    if difference = SQLiteQueryOracle.difference(expected.outcome, actual.outcome, true)
      @report.difference("#{name}\n  TEMP schema at the end\n  #{difference}")
    end
  end

  private def first_word(sql : String) : String
    text = sql.lstrip
    while text.starts_with?("--")
      text = (text.split('\n', 2)[1]? || "").lstrip
    end
    text.split(2).first?.try(&.upcase) || ""
  end

  private def schema_change?(sql : String) : Bool
    first_word(sql).in?("CREATE", "DROP", "ALTER")
  end

  # Rows compare in order when the statement orders them.
  private def ordered?(sql : String) : Bool
    sql.upcase.includes?("ORDER BY") || first_word(sql).in?("INSERT", "REPLACE", "PRAGMA")
  end
end

module TriggerScenarios
  # The scenarios of a corpus file: each `-- scenario: NAME` line starts one.
  def self.from_corpus(path : String) : Array(TriggerScenario)
    scenarios = [] of TriggerScenario
    name = nil.as(String?)
    block = [] of String
    finish = -> do
      if current = name
        statements = [] of String
        text = String.build { |io| block.each { |line| io << line << '\n' } }
        text.split("\n-- swap\n").each_with_index do |part, index|
          statements << "-- swap" if index > 0
          statements.concat(SQLiteSQLOracle.split_statements(part).reject(&.strip.empty?))
        end
        scenarios << TriggerScenario.new(current, statements)
      end
    end
    File.each_line(path) do |line|
      if line.starts_with?("-- scenario:")
        finish.call
        name = line.lchop("-- scenario:").strip
        block = [] of String
      else
        block << line
      end
    end
    finish.call
    scenarios
  end

  # The scenarios of extracted Tcl test blocks: one per test file.
  def self.from_records(path : String) : Array(TriggerScenario)
    by_file = {} of String => Array(String)
    File.each_line(path) do |line|
      next if line.blank?
      record = TriggerRecord.from_json(line)
      file = record.source.split(':').first
      list = by_file[file] ||= [] of String
      SQLiteSQLOracle.split_statements(record.sql).each do |statement|
        list << statement unless statement.strip.empty?
      end
    end
    by_file.map { |file, statements| TriggerScenario.new(file, statements) }
  end
end
