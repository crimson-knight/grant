# Compares Grant's SQLite engine with C SQLite on writes: both run the same
# statements, each on its own database file, and after every statement the
# rows, the error, changes(), last_insert_rowid() and total_changes() are
# compared; at checkpoints C reads both files and they must hold the same
# schema and rows, with the engine's file passing C's integrity_check.
#
#   crystal-alpha run scripts/sqlite_engine_write_differential.cr -- replay CORPUS SEED REPORT_DIR
#     Every statement of the corpus in order (parameters bound with seeded
#     values), the files compared every 250 statements and at the end.
#
#   crystal-alpha run scripts/sqlite_engine_write_differential.cr -- random SEED COUNT WORKERS REPORT_DIR
#     COUNT random sequences (a random schema, then random inserts, upserts,
#     updates, deletes, transactions, savepoints and schema changes), split
#     over WORKERS processes; the files compared after each sequence.
#
# Scratch: one directory per worker under REPORT_DIR/work, emptied after
# every sequence, so a run never holds more than a few small databases.
#
# Link a pinned libsqlite3 with --link-flags "-L DIR -Wl,-rpath,DIR".
require "file_utils"
require "../spec/support/sqlite_engine/write_oracle"

private alias Value = Grant::SQLiteEngine::Value

class WriteReport
  getter counts = Hash(String, Int64).new(0_i64)
  getter list_of_differences = [] of String
  getter skipped = Hash(String, Int64).new(0_i64)
  getter list_of_examples = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }

  def count(key : String, amount : Int64 = 1_i64) : Nil
    @counts[key] += amount
  end

  def skip(reason : String, example : String) : Nil
    @skipped[reason] += 1
    list = @list_of_examples[reason]
    list << example[0, 300] if list.size < 5
  end

  def difference(text : String) : Nil
    @counts["differences"] += 1
    @list_of_differences << text if @list_of_differences.size < 2_000
  end

  def merge(other_text : String) : Nil
    other_text.each_line do |line|
      if match = line.match(/\Acount\t(.+)\t(\d+)\z/)
        @counts[match[1]] += match[2].to_i64
      elsif match = line.match(/\Askip\t(.+)\t(\d+)\z/)
        @skipped[match[1]] += match[2].to_i64
      elsif match = line.match(/\Aexample\t([^\t]+)\t(.*)\z/)
        list = @list_of_examples[match[1]]
        list << match[2] if list.size < 5
      elsif match = line.match(/\Adifference\t(.*)\z/)
        @list_of_differences << match[1].gsub("\\n", "\n") if @list_of_differences.size < 2_000
      end
    end
  end

  def serialize : String
    String.build do |io|
      @counts.each { |key, value| io << "count\t" << key << '\t' << value << '\n' }
      @skipped.each { |key, value| io << "skip\t" << key << '\t' << value << '\n' }
      @list_of_examples.each { |key, list| list.each { |example| io << "example\t" << key << '\t' << example.gsub('\n', ' ') << '\n' } }
      @list_of_differences.each { |text| io << "difference\t" << text.gsub("\n", "\\n") << '\n' }
    end
  end

  def write(directory : String, title : String) : Nil
    Dir.mkdir_p(directory)
    @counts["differences"] += 0
    File.write(File.join(directory, "differences.txt"), @list_of_differences.join("\n\n") + "\n")
    summary = String.build do |io|
      io << title << '\n'
      io << "C SQLite " << String.new(SQLiteSQLOracle::LibOracle.libversion) << ' ' << String.new(SQLiteSQLOracle::LibOracle.sourceid) << '\n'
      @counts.keys.sort.each { |key| io << key << ": " << @counts[key] << '\n' }
      io << "skipped, by reason:\n"
      @skipped.keys.sort.each do |key|
        io << "  " << key << ": " << @skipped[key] << '\n'
        @list_of_examples[key].each { |example| io << "      e.g. " << example << '\n' }
      end
    end
    File.write(File.join(directory, "summary.txt"), summary)
    puts summary
  end
end

# Runs one statement on both and records the outcome.
module WriteStep
  def self.run(pair : SQLiteWriteOracle::Pair, sql : String, parameters : Array(Value), report : WriteReport,
               context : String, ordered : Bool) : Bool
    report.count("statements")
    expected = pair.c_step(sql, parameters)
    actual = begin
      pair.engine_step(sql, parameters)
    rescue error : Grant::SQLiteEngine::UnsupportedSQL
      report.skip("engine: #{error.message}", sql)
      # Keep the engine's file in step with C's where the statement wrote.
      return false
    end
    report.count("C errors") if expected.outcome.error
    report.count("rows compared", expected.outcome.list_of_rows.size.to_i64)
    if difference = SQLiteWriteOracle::Pair.difference(expected, actual, ordered)
      report.difference("#{context}\n  #{sql}\n  parameters #{parameters.inspect}\n  #{difference}")
      return false
    end
    report.count("statements matching C")
    true
  end

  def self.ordered?(sql : String) : Bool
    upper = sql.upcase
    return false if upper.matches?(/\A\s*(UPDATE|DELETE)/)
    upper.includes?("ORDER BY") || upper.matches?(/\A\s*(INSERT|REPLACE|PRAGMA)/)
  end
end

# The corpus, statement by statement in order.
class CorpusReplay
  def initialize(@corpus : String, @seed : Int64, @report : WriteReport, @work : String)
  end

  def run : Nil
    pair = SQLiteWriteOracle::Pair.new(@work, "replay")
    random = Random.new(@seed)
    lines = File.read_lines(@corpus).reject(&.blank?)
    begin
      lines.each_with_index do |sql, index|
        count = pair.c_connection.parameter_count(sql) || 0
        parameters = Array(Value).new(count) { |position| CorpusReplay.value(random, position) }
        WriteStep.run(pair, sql, parameters, @report, "statement #{index + 1}", WriteStep.ordered?(sql))
        if (index + 1) % 250 == 0 && pair.autocommit? && !pair.session.in_transaction?
          check_files(pair, index + 1)
        end
      end
      pair.c_step("ROLLBACK") unless pair.autocommit?
      pair.engine_step("ROLLBACK") if pair.session.in_transaction?
      check_files(pair, lines.size)
      @report.count("corpus statements", lines.size.to_i64)
    ensure
      pair.close
    end
  end

  private def check_files(pair : SQLiteWriteOracle::Pair, position : Int32) : Nil
    @report.count("file comparisons")
    if difference = pair.file_difference
      @report.difference("files after statement #{position}\n  #{difference}")
    end
  end

  def self.value(random : Random, position : Int32) : Value
    case random.rand(20)
    when 0      then nil
    when 1, 2   then "v#{random.rand(6)}"
    when 3      then random.rand(6) + 0.5
    when 4      then "2026-11-#{10 + random.rand(9)} 10:00:00.000000"
    else             (random.rand(8) + 1).to_i64
    end
  end
end

# Random schemas and write sequences.
class RandomWrites
  TYPES = ["INTEGER", "VARCHAR(20)", "TEXT", "REAL", "NUMERIC", "BOOL", "DATETIME", "BLOB", ""]
  CONFLICTS = ["", "OR IGNORE ", "OR REPLACE ", "OR FAIL ", "OR ABORT ", "OR ROLLBACK "]
  ACTIONS = ["", " ON DELETE CASCADE", " ON DELETE SET NULL", " ON DELETE RESTRICT", " ON UPDATE CASCADE", " ON DELETE SET DEFAULT"]

  record Column, name : String, type : String, unique : Bool, not_null : Bool

  record Table, name : String, list_of_columns : Array(Column), rowid_alias : Bool, without_rowid : Bool

  def initialize(@random : Random)
  end

  def value : String
    case @random.rand(14)
    when 0     then "NULL"
    when 1     then "'a'"
    when 2     then "'B'"
    when 3     then "'b'"
    when 4     then "1.5"
    when 5     then "'3'"
    when 6     then "x'01'"
    when 7     then "-1"
    else            (@random.rand(6)).to_s
    end
  end

  def schema : {Array(String), Array(Table)}
    statements = [] of String
    tables = [] of Table
    statements << "PRAGMA foreign_keys = ON" if @random.rand(2) == 0
    (@random.rand(3) + 1).times do |table_index|
      name = "t#{table_index}"
      definitions = [] of String
      columns = [] of Column
      key_kind = @random.rand(10)
      rowid_alias = false
      without_rowid = false
      case key_kind
      when 0..5
        definitions << "id INTEGER PRIMARY KEY#{@random.rand(3) == 0 ? " AUTOINCREMENT" : ""}"
        columns << Column.new("id", "INTEGER", true, false)
        rowid_alias = true
      when 6
        definitions << "id BIGINT PRIMARY KEY"
        columns << Column.new("id", "BIGINT", true, false)
      end
      (@random.rand(3) + 2).times do |column_index|
        column_name = "c#{column_index}"
        type = TYPES.sample(@random)
        parts = [column_name, type]
        unique = @random.rand(7) == 0
        not_null = @random.rand(5) == 0
        parts << "NOT NULL" if not_null
        parts << "DEFAULT #{value}" if @random.rand(3) == 0
        parts << "UNIQUE" if unique
        parts << "COLLATE NOCASE" if type.includes?("CHAR") || type == "TEXT" ? @random.rand(4) == 0 : false
        parts << "CHECK (#{column_name} IS NULL OR #{column_name} <> 'bad')" if @random.rand(8) == 0
        if table_index > 0 && @random.rand(4) == 0
          parent = tables.sample(@random)
          if parent.rowid_alias
            parts << "REFERENCES #{parent.name}(id)#{ACTIONS.sample(@random)}"
          end
        end
        definitions << parts.reject(&.empty?).join(' ')
        columns << Column.new(column_name, type, unique, not_null)
      end
      if key_kind == 7
        definitions << "PRIMARY KEY (c0, c1)"
      elsif key_kind == 8 && @random.rand(2) == 0
        definitions << "UNIQUE (c0, c1)"
      end
      if key_kind == 9 && @random.rand(3) == 0
        definitions << "PRIMARY KEY (c0)"
        without_rowid = true
      end
      statements << "CREATE TABLE #{name} (#{definitions.join(", ")})#{without_rowid ? " WITHOUT ROWID" : ""}"
      tables << Table.new(name, columns, rowid_alias, without_rowid)
      @random.rand(3).times do |index_number|
        picked = columns.reject { |column| column.name == "id" }.sample(@random.rand(2) + 1, @random).map(&.name)
        unique = @random.rand(3) == 0 ? "UNIQUE " : ""
        partial = @random.rand(5) == 0 ? " WHERE #{picked[0]} IS NOT NULL" : ""
        statements << "CREATE #{unique}INDEX #{name}_i#{index_number} ON #{name} (#{picked.join(", ")})#{partial}"
      end
    end
    {statements, tables}
  end

  def predicate(table : Table) : String
    column = table.list_of_columns.sample(@random).name
    case @random.rand(7)
    when 0 then "#{column} = #{value}"
    when 1 then "#{column} > #{value}"
    when 2 then "#{column} IS NULL"
    when 3 then "rowid = #{@random.rand(6)}"
    when 4 then "#{column} IN (#{value}, #{value})"
    when 5 then "1"
    else        "#{column} <> #{value}"
    end
  end

  def expression(table : Table, column : String) : String
    case @random.rand(6)
    when 0 then "#{column} + 1"
    when 1 then "#{column} || 'x'"
    when 2 then "upper(#{column})"
    else        value
    end
  end

  def statement(tables : Array(Table), savepoints : Array(String)) : String
    table = tables.sample(@random)
    columns = table.list_of_columns
    returning = @random.rand(6) == 0 ? " RETURNING *" : ""
    case @random.rand(20)
    when 0..6
      picked = columns.sample(@random.rand(columns.size) + 1, @random)
      rows = (0..@random.rand(2)).map { "(#{picked.map { value }.join(", ")})" }
      upsert = ""
      if @random.rand(5) == 0 && returning.empty?
        target = columns.find(&.unique)
        upsert = if target && @random.rand(2) == 0
                   " ON CONFLICT (#{target.name}) DO UPDATE SET #{picked[0].name} = excluded.#{picked[0].name}"
                 else
                   " ON CONFLICT DO NOTHING"
                 end
      end
      conflict = upsert.empty? ? CONFLICTS.sample(@random) : ""
      "INSERT #{conflict}INTO #{table.name} (#{picked.map(&.name).join(", ")}) VALUES #{rows.join(", ")}#{upsert}#{returning}"
    when 7
      other = tables.sample(@random)
      width = Math.min(columns.size, other.list_of_columns.size)
      "INSERT #{CONFLICTS.sample(@random)}INTO #{table.name} (#{columns.first(width).map(&.name).join(", ")}) SELECT #{other.list_of_columns.first(width).map(&.name).join(", ")} FROM #{other.name} LIMIT 3"
    when 8..10
      column = columns.sample(@random).name
      "UPDATE #{CONFLICTS.sample(@random)}#{table.name} SET #{column} = #{expression(table, column)} WHERE #{predicate(table)}#{returning}"
    when 11, 12
      "DELETE FROM #{table.name} WHERE #{predicate(table)}#{returning}"
    when 13
      savepoints.empty? ? "BEGIN" : "COMMIT"
    when 14
      name = "s#{savepoints.size}"
      savepoints << name
      "SAVEPOINT #{name}"
    when 15
      if name = savepoints.sample?(@random)
        "ROLLBACK TO #{name}"
      else
        "ROLLBACK"
      end
    when 16
      if name = savepoints.sample?(@random)
        "RELEASE #{name}"
      else
        "SELECT * FROM #{table.name} ORDER BY rowid"
      end
    when 17
      "REPLACE INTO #{table.name} (#{columns.first.name}) VALUES (#{value})"
    when 18
      "SELECT count(*), sum(length(#{columns.sample(@random).name})) FROM #{table.name}"
    else
      "SELECT * FROM #{table.name}"
    end
  end
end

class RandomDifferential
  def initialize(@seed : Int64, @first : Int32, @count : Int32, @report : WriteReport, @work : String)
  end

  def run : Nil
    @count.times do |offset|
      number = @first + offset
      random = Random.new(@seed &+ number.to_i64 &* 1_000_003)
      generator = RandomWrites.new(random)
      directory = File.join(@work, "sequence")
      pair = SQLiteWriteOracle::Pair.new(directory, "random")
      begin
        statements, tables = generator.schema
        savepoints = [] of String
        statements.each { |sql| WriteStep.run(pair, sql, [] of Value, @report, "sequence #{number} (seed #{@seed})", true) }
        (random.rand(20) + 5).times do
          sql = generator.statement(tables, savepoints)
          WriteStep.run(pair, sql, [] of Value, @report, "sequence #{number} (seed #{@seed})", WriteStep.ordered?(sql))
          savepoints.clear if sql.matches?(/\A(COMMIT|ROLLBACK\z|BEGIN)/)
        end
        pair.c_step("ROLLBACK") unless pair.autocommit?
        pair.engine_step("ROLLBACK") if pair.session.in_transaction?
        @report.count("sequences")
        if difference = pair.file_difference
          @report.difference("files after sequence #{number} (seed #{@seed})\n  #{difference}")
        end
      ensure
        pair.close
        FileUtils.rm_rf(directory)
      end
    end
  end
end

mode = ARGV[0]? || abort "usage: replay CORPUS SEED REPORT_DIR | random SEED COUNT WORKERS REPORT_DIR"
started = Time.instant
report = WriteReport.new
case mode
when "replay"
  corpus, seed, directory = ARGV[1], ARGV[2].to_i64, ARGV[3]
  work = File.join(directory, "work")
  FileUtils.rm_rf(work)
  CorpusReplay.new(corpus, seed, report, work).run
  FileUtils.rm_rf(work)
  report.write(directory, "replay #{corpus} seed #{seed}, #{(Time.instant - started).total_seconds.round(1)} s")
when "random"
  seed, count, workers, directory = ARGV[1].to_i64, ARGV[2].to_i, ARGV[3].to_i, ARGV[4]
  Dir.mkdir_p(directory)
  share = (count + workers - 1) // workers
  processes = (0...workers).compact_map do |worker|
    first = worker * share
    next if first >= count
    size = Math.min(share, count - first)
    output = File.join(directory, "worker-#{worker}.txt")
    {Process.new(Process.executable_path || PROGRAM_NAME, ["random-worker", seed.to_s, first.to_s, size.to_s, directory, output],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit), output}
  end
  processes.each do |process, output|
    status = process.wait
    report.count("workers failed") unless status.success?
    report.merge(File.read(output)) if File.exists?(output)
    File.delete?(output)
  end
  FileUtils.rm_rf(File.join(directory, "work"))
  report.write(directory, "random seed #{seed}, #{count} sequences over #{workers} workers, #{(Time.instant - started).total_seconds.round(1)} s")
when "random-worker"
  seed, first, size, directory, output = ARGV[1].to_i64, ARGV[2].to_i, ARGV[3].to_i, ARGV[4], ARGV[5]
  work = File.join(directory, "work", "w#{first}")
  RandomDifferential.new(seed, first, size, report, work).run
  File.write(output, report.serialize)
else
  abort "unknown mode #{mode}"
end
