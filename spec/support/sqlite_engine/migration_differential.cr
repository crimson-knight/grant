require "file_utils"
require "./write_oracle"

# Migrations replayed on Grant's SQLite engine and on C SQLite, each on a
# fresh pair of database files, with every difference reported: a
# statement's rows (RETURNING, PRAGMA, SELECT), its error message,
# changes() and last_insert_rowid(); and at every probe point the
# `sqlite_schema` rows, every table's contents, PRAGMA table_info,
# table_xinfo, index_list, index_info, index_xinfo, foreign_key_list,
# foreign_key_check, user_version and schema_version, C's dump and
# integrity_check of both files, and `/usr/bin/sqlite3`'s integrity_check of
# the engine's file (when that shell exists).
#
# A migration is a `.sql` file split into statements with C's
# sqlite3_complete. A line `-- +micrate Down` probes both databases before
# the Down section runs; every file is probed at its end. The corpus is
# spec/grant/sqlite_engine/migrations. Links libsqlite3, so only specs and
# scripts load it.
module MigrationDifferential
  alias Value = Grant::SQLiteEngine::Value

  SHELL = "/usr/bin/sqlite3"

  CORPUS = File.expand_path("../../grant/sqlite_engine/migrations", __DIR__)

  record Statement, sql : String, line : Int32, probe_before : Bool

  # A difference the engine keeps on purpose, found by the migration file
  # it occurs in and a text the difference contains.
  record Remaining, file : String, needle : String, reason : String

  # The differences that stay, each with why.
  LIST_OF_REMAINING = [
    Remaining.new("frameworks/ecto.sql", "DROP COLUMN of a WITHOUT ROWID table",
      "DROP COLUMN of a WITHOUT ROWID table is not implemented (UnsupportedSQL); no framework migration in the corpus " \
      "drops a column of a WITHOUT ROWID table except this contrived Ecto case"),
    Remaining.new("frameworks/rebuild_savepoints_and_backfills.sql", "row_number()",
      "window functions are a query feature the engine does not compile (UnsupportedSQL), outside this chunk"),
    Remaining.new("frameworks/rebuild_savepoints_and_backfills.sql", "PRAGMA table_info(\"roster\")",
      "PRAGMA table_info of a view: the engine keeps no column origin for a view's columns, which C's declared types " \
      "come from, so it answers no rows (Grant's catalog asks only about tables)"),
    Remaining.new("frameworks/rebuild_savepoints_and_backfills.sql", "PRAGMA table_xinfo(\"roster\")",
      "PRAGMA table_xinfo of a view: as table_info"),
    Remaining.new("grant/spec_suite_migrations.sql", "PRAGMA table_info(\"m03_c\")",
      "PRAGMA table_info of a view (m03_c is a view here): as above"),
    Remaining.new("grant/spec_suite_migrations.sql", "PRAGMA table_xinfo(\"m03_c\")",
      "PRAGMA table_xinfo of a view: as above"),
    Remaining.new("frameworks/table_features.sql", "PRAGMA table_list\n",
      "the unfiltered PRAGMA table_list lists C's schema hash order, which depends on the allocator; the engine lists " \
      "sqlite_schema order with the same rows (compared by the ORDER BY query next to it)"),
    Remaining.new("frameworks/pragmas_and_errors.sql", "PRAGMA case_sensitive_like\n",
      "PRAGMA case_sensitive_like is write-only in C and LIKE honors it; the engine remembers the value, reads it " \
      "back and keeps LIKE case-insensitive (no migration in the corpus sets it)"),
    Remaining.new("frameworks/pragmas_and_errors.sql", "PRAGMA schema_version",
      "plain VACUUM is a no-op in the engine: C rebuilds the file and adds 1 to schema_version"),
    Remaining.new("frameworks/pragmas_and_errors.sql", "changes(): C 1, engine 0",
      "an INSERT into a table whose FOREIGN KEY names a missing table, with foreign_keys on, fails in C while it is " \
      "prepared (changes() untouched) and in the engine while it runs (changes() set to 0); C's changes() stays 1 " \
      "until the next INSERT, UPDATE or DELETE"),
    Remaining.new("frameworks/shapes_and_backfills.sql", "TEMP views",
      "CREATE TEMP VIEW (views of the temp schema) is not implemented (UnsupportedSQL)"),
    Remaining.new("frameworks/shapes_and_backfills.sql", "FROM recent",
      "follows from the refused CREATE TEMP VIEW"),
  ]

  # The remaining difference *text* (from *file*) is, or nil.
  def self.remaining(file : String, text : String) : Remaining?
    LIST_OF_REMAINING.find { |rule| rule.file == file && text.includes?(rule.needle) }
  end

  # The statements of a migration file in order; a statement after a
  # `-- +micrate Down` line carries probe_before.
  def self.statements(text : String) : Array(Statement)
    list = [] of Statement
    buffer = ""
    start_line = 0
    probe_pending = false
    text.each_line.with_index(1) do |line, number|
      if buffer.empty?
        stripped = line.strip
        next if stripped.empty?
        if stripped.starts_with?("--")
          probe_pending = true if stripped.starts_with?("-- +micrate Down")
          next
        end
        start_line = number
      end
      buffer += line + '\n'
      if SQLiteSQLOracle::LibOracle.complete(buffer) != 0
        list << Statement.new(buffer.strip.rchop(';').strip, start_line, probe_pending)
        probe_pending = false
        buffer = ""
      end
    end
    list << Statement.new(buffer.strip, start_line, probe_pending) unless buffer.empty?
    list << Statement.new("", 0, true) if probe_pending
    list
  end

  def self.quoted(name : String) : String
    %("#{name.gsub('"', "\"\"")}")
  end

  # The statement's first keyword, upper case.
  def self.verb(sql : String) : String
    sql.lstrip.split(2).first?.try(&.upcase) || ""
  end

  # Every `.sql` file under *corpus*, by its path relative to *corpus*.
  def self.list_of_migrations(corpus : String = CORPUS) : Array({String, String})
    Dir.glob(File.join(corpus, "**", "*.sql")).sort!.map { |path| {Path[path].relative_to(corpus).to_s, path} }
  end

  def self.shell_version : String
    return "#{SHELL} (absent)" unless File::Info.executable?(SHELL)
    output = IO::Memory.new
    Process.run(SHELL, ["--version"], output: output)
    "#{SHELL} #{output.to_s.strip}"
  end

  # Counts, the differences found (by migration file), and how many of
  # them are remaining ones.
  class Report
    getter counts = Hash(String, Int64).new(0_i64)
    getter list_of_differences = [] of {String, String}

    def count(key : String, amount : Int64 = 1_i64) : Nil
      @counts[key] += amount
    end

    def difference(file : String, text : String) : Nil
      @counts["differences"] += 1
      @list_of_differences << {file, text}
    end

    # The differences no remaining rule explains.
    def list_of_unexplained : Array(String)
      @list_of_differences.compact_map { |file, text| MigrationDifferential.remaining(file, text) ? nil : text }
    end

    # The remaining rules no difference matched: a fixed difference leaves
    # its rule behind, and the list must say so.
    def list_of_unused_rules : Array(Remaining)
      LIST_OF_REMAINING.reject do |rule|
        @list_of_differences.any? { |file, text| file == rule.file && text.includes?(rule.needle) }
      end
    end

    # summary.txt, differences.txt (every difference, each marked
    # unexplained or with its remaining reason) and remaining.txt.
    def write(directory : String, title : String) : String
      Dir.mkdir_p(directory)
      marked = @list_of_differences.map do |file, text|
        rule = MigrationDifferential.remaining(file, text)
        "#{rule ? "REMAINING (#{rule.reason})" : "UNEXPLAINED"}\n#{text}"
      end
      File.write(File.join(directory, "differences.txt"), marked.join("\n\n") + "\n")
      remaining = String.build do |io|
        LIST_OF_REMAINING.each do |rule|
          matched = @list_of_differences.select { |file, text| file == rule.file && text.includes?(rule.needle) }
          io << "== " << rule.file << (rule.needle.empty? ? "" : " / #{rule.needle.strip}") << " (" << matched.size << " differences)\n"
          io << "   why it stays: " << rule.reason << '\n'
          matched.first(3).each { |_, text| text.each_line { |line| io << "   | " << line << '\n' } }
          io << '\n'
        end
      end
      File.write(File.join(directory, "remaining.txt"), remaining)
      summary = String.build do |io|
        io << title << '\n'
        io << "C SQLite " << String.new(SQLiteSQLOracle::LibOracle.libversion) << ' ' << String.new(SQLiteSQLOracle::LibOracle.sourceid) << '\n'
        io << MigrationDifferential.shell_version << '\n'
        @counts.keys.sort!.each { |key| io << key << ": " << @counts[key] << '\n' }
        io << "differences explained by the remaining list: " << (@list_of_differences.size - list_of_unexplained.size) << '\n'
        io << "differences unexplained: " << list_of_unexplained.size << '\n'
        io << "remaining rules with no difference: " << list_of_unused_rules.size << '\n'
      end
      File.write(File.join(directory, "summary.txt"), summary)
      summary
    end
  end

  # One migration file on a fresh pair.
  class Replay
    @copy_pending = false

    def initialize(@path : String, @name : String, @report : Report, @work : String)
    end

    def run : Nil
      statements = MigrationDifferential.statements(File.read(@path))
      @report.count("migrations")
      pair = SQLiteWriteOracle::Pair.new(@work, "migration")
      begin
        statements.each do |statement|
          probe(pair, "before line #{statement.line}") if statement.probe_before
          next if statement.sql.empty?
          step(pair, statement.sql, "#{@name}:#{statement.line}")
        end
        pair.c_step("ROLLBACK") unless pair.autocommit?
        pair.engine_step("ROLLBACK") if pair.session.in_transaction?
        probe(pair, "at the end")
      ensure
        pair.close
        FileUtils.rm_rf(@work)
      end
    end

    private def difference(text : String) : Nil
      @report.difference(@name, text)
    end

    # Runs one statement on both and records any difference. After a
    # statement only C ran, the engine's file takes a copy of C's at the
    # next point outside a transaction, so later statements start alike.
    private def step(pair : SQLiteWriteOracle::Pair, sql : String, context : String, probe : Bool = false) : Nil
      @report.count(probe ? "probe statements" : "statements")
      if @copy_pending && idle?(pair)
        pair.copy_c_file_to_engine
        @copy_pending = false
      end
      expected = pair.c_step(sql)
      actual = begin
        pair.engine_step(sql)
      rescue error : Grant::SQLiteEngine::UnsupportedSQL
        difference("#{context}\n  #{sql}\n  engine: unsupported #{error.message}\n  C: #{outcome_text(expected.outcome)}")
        @copy_pending = true if expected.outcome.error.nil?
        pair.changes_in_step = false
        pair.rowid_in_step = false
        return
      end
      expected = normalized(expected, pair, sql)
      if found = SQLiteWriteOracle::Pair.difference(expected, actual, ordered?(sql), pair.changes_in_step?, pair.rowid_in_step?)
        difference("#{context}\n  #{sql}\n  #{found}\n  C:      #{outcome_text(expected.outcome)}\n  engine: #{outcome_text(actual.outcome)}")
      else
        @report.count(probe ? "probe statements matching C" : "statements matching C")
      end
      line_up(pair, sql) if expected.outcome.error.nil? && actual.outcome.error.nil?
    end

    # Neither connection is inside a transaction.
    private def idle?(pair : SQLiteWriteOracle::Pair) : Bool
      pair.autocommit? && !pair.session.in_transaction?
    end

    # changes() lines up again once both ran the same INSERT, UPDATE or
    # DELETE; last_insert_rowid() once both ran the same INSERT.
    private def line_up(pair : SQLiteWriteOracle::Pair, sql : String) : Nil
      verb = MigrationDifferential.verb(sql)
      pair.changes_in_step = true if verb.in?("INSERT", "REPLACE", "UPDATE", "DELETE", "WITH")
      pair.rowid_in_step = true if verb.in?("INSERT", "REPLACE")
    end

    private def outcome_text(outcome : SQLiteQueryOracle::Outcome) : String
      return "error #{outcome.error.inspect}" if outcome.error
      rows = outcome.list_of_rows.first(12).map { |row| SQLiteQueryOracle.row_token(row) }
      more = outcome.list_of_rows.size > 12 ? " ... (#{outcome.list_of_rows.size} rows)" : ""
      "#{outcome.list_of_column_names.join(", ")} => [#{rows.join("; ")}]#{more}"
    end

    # The file name each connection reports for its own database; and the
    # result column C names for an ALTER TABLE ... ADD COLUMN that checks
    # existing rows (the nested query it compiles in), which returns no
    # rows.
    private def normalized(result : SQLiteWriteOracle::StepResult, pair : SQLiteWriteOracle::Pair, sql : String) : SQLiteWriteOracle::StepResult
      c_path = File.realpath(pair.c_path)
      engine_path = File.realpath(pair.engine_path)
      outcome = result.outcome
      rows = outcome.list_of_rows.map { |row| row.map { |value| value == c_path ? engine_path.as(Value) : value } }
      names = outcome.list_of_column_names
      names = [] of String if rows.empty? && MigrationDifferential.verb(sql) == "ALTER"
      result.copy_with(outcome: outcome.copy_with(list_of_rows: rows, list_of_column_names: names))
    end

    private def ordered?(sql : String) : Bool
      verb = MigrationDifferential.verb(sql)
      return false if verb.in?("UPDATE", "DELETE")
      sql.upcase.includes?("ORDER BY") || verb.in?("INSERT", "REPLACE", "PRAGMA")
    end

    # The schema, every table's rows and the PRAGMA outputs, statement by
    # statement on both, then both files as C reads them.
    private def probe(pair : SQLiteWriteOracle::Pair, label : String) : Nil
      @report.count("probes")
      context = "#{@name} probe #{label}"
      step(pair, "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name", context, true)
      step(pair, "PRAGMA user_version", context, true)
      step(pair, "PRAGMA schema_version", context, true)
      step(pair, "PRAGMA foreign_key_check", context, true)
      schema = pair.c_connection.query("SELECT type, name, sql FROM sqlite_schema ORDER BY type, name")
      schema.list_of_rows.each do |row|
        type, name, sql = row[0].as(String), row[1].as(String), row[2].as?(String) || ""
        quoted = MigrationDifferential.quoted(name)
        case type
        when "table", "view"
          %w[table_info table_xinfo index_list foreign_key_list].each do |pragma|
            step(pair, "PRAGMA #{pragma}(#{quoted})", context, true)
          end
          rows = if type == "table" && !sql.upcase.includes?("WITHOUT ROWID")
                   "SELECT rowid, * FROM #{quoted} ORDER BY rowid"
                 else
                   "SELECT * FROM #{quoted} ORDER BY 1, 2"
                 end
          step(pair, rows, context, true)
        when "index"
          step(pair, "PRAGMA index_info(#{quoted})", context, true)
          step(pair, "PRAGMA index_xinfo(#{quoted})", context, true)
        end
      end
      # The files are compared as they stand, before a skipped write's copy.
      return unless idle?(pair)
      if found = pair.file_difference
        difference("#{context}: files\n  #{found}")
      end
      return unless File::Info.executable?(SHELL)
      output = IO::Memory.new
      Process.run(SHELL, [pair.engine_path, "PRAGMA integrity_check"], output: output, error: output)
      unless output.to_s.strip == "ok"
        difference("#{context}: #{SHELL} integrity_check of the engine's file\n  #{output.to_s.strip[0, 400]}")
      end
    end
  end

  # Replays every migration of *corpus*, each in its own directory under
  # *work*.
  def self.run(corpus : String, work : String) : Report
    report = Report.new
    list_of_migrations(corpus).each do |name, path|
      Replay.new(path, name, report, File.join(work, name.gsub('/', '_'))).run
    end
    FileUtils.rm_rf(work)
    report
  end
end
