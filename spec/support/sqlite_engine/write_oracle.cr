require "file_utils"
require "./query_oracle"

# C SQLite and Grant's engine fed the same statements, each on its own
# database file: after every statement the rows (RETURNING, PRAGMA), the
# error, changes() and last_insert_rowid() are compared, and at any point
# both files can be dumped by C (so the engine's file is read by C, not by
# the engine) and the engine's file checked with C's integrity_check.
# Links libsqlite3, so only specs and scripts load it.
module SQLiteWriteOracle
  alias Value = Grant::SQLiteEngine::Value
  alias Outcome = SQLiteQueryOracle::Outcome

  @[Link("sqlite3")]
  lib LibWriteOracle
    fun changes64 = sqlite3_changes64(database : SQLiteSQLOracle::LibOracle::Database) : Int64
    fun total_changes64 = sqlite3_total_changes64(database : SQLiteSQLOracle::LibOracle::Database) : Int64
    fun last_insert_rowid = sqlite3_last_insert_rowid(database : SQLiteSQLOracle::LibOracle::Database) : Int64
    fun get_autocommit = sqlite3_get_autocommit(database : SQLiteSQLOracle::LibOracle::Database) : Int32
  end

  # One statement's result on one engine; *total_changes* is how much the
  # statement added to total_changes(), so one miscount is reported once.
  record StepResult, outcome : Outcome, changes : Int64, last_insert_rowid : Int64, total_changes : Int64

  # A C connection and an engine session, on two files in *directory*.
  class Pair
    # Both sides write in journal_mode=WAL. The engine's file is then read
    # by a child process (`dump_command`), never by C in this process: POSIX
    # locks belong to the process, so a C connection here would take the
    # engine's locks for its own and, closing, remove the engine's live WAL.
    class_property? wal = false
    # The program and arguments that print `Pair.child_dump` of a path
    # given as the last argument.
    class_property dump_command : Array(String) = [] of String

    getter c_path : String
    getter engine_path : String
    getter c_connection : SQLiteQueryOracle::Connection
    getter session : Grant::SQLiteEngine::Query::Session
    # False after a statement only C ran changed changes(), until both run
    # the next INSERT, UPDATE or DELETE.
    property? changes_in_step = true
    # The same for last_insert_rowid(), until both run the next INSERT.
    property? rowid_in_step = true

    def initialize(@directory : String, name : String = "db")
      Dir.mkdir_p(@directory)
      @c_path = File.join(@directory, "#{name}-c.db")
      @engine_path = File.join(@directory, "#{name}-engine.db")
      [@c_path, @engine_path].each do |path|
        File.delete?(path)
        File.delete?("#{path}-journal")
      end
      @c_connection = SQLiteQueryOracle::Connection.new(@c_path)
      @c_connection.query("PRAGMA journal_mode=WAL") if Pair.wal?
      @session = Pair.open_session(@engine_path)
    end

    def self.open_session(path : String) : Grant::SQLiteEngine::Query::Session
      pager = Grant::SQLiteEngine::Pager.open_read_write(Grant::SQLiteEngine::PosixFileSystem.new, path)
      database = Grant::SQLiteEngine::Database.new(pager, File.realpath(path))
      database.journal_mode = Grant::SQLiteEngine::JournalMode::Wal if Pair.wal?
      Grant::SQLiteEngine::Query::Session.new(database)
    end

    # integrity_check's rows, then the dump, of the file at *path*, as JSON.
    def self.child_dump(path : String) : String
      connection = SQLiteQueryOracle::Connection.new(path)
      begin
        integrity = connection.query("PRAGMA integrity_check")
        status = integrity.error.nil? && integrity.list_of_rows == [["ok"] of Value] ? "ok" : "#{integrity.list_of_rows.first(5)} #{integrity.error}"
        ([status] + dump(connection)).to_json
      ensure
        connection.close
      end
    end

    private def child_engine_dump : Array(String)
      command = Pair.dump_command
      output = IO::Memory.new
      status = Process.run(command.first, command[1..] + [@engine_path], output: output, error: output)
      raise "the dump process failed: #{output.to_s[0, 400]}" unless status.success?
      Array(String).from_json(output.to_s)
    end

    def close : Nil
      @c_connection.close
      @session.database.close
    end

    @c_total = 0_i64
    @engine_total = 0_i64

    def c_step(sql : String, parameters : Array(Value) = [] of Value) : StepResult
      outcome = @c_connection.query(sql, parameters)
      handle = @c_connection.handle
      total = LibWriteOracle.total_changes64(handle)
      delta = total - @c_total
      @c_total = total
      StepResult.new(outcome, LibWriteOracle.changes64(handle), LibWriteOracle.last_insert_rowid(handle), delta)
    end

    # Runs *sql* under the statement read lock, as Grant's driver does (in
    # WAL mode the read lock is the snapshot the statement reads).
    def engine_step(sql : String, parameters : Array(Value) = [] of Value) : StepResult
      @session.begin_statement_read
      outcome = begin
        SQLiteQueryOracle.engine_query(@session, sql, parameters)
      ensure
        @session.end_statement_read
      end
      delta = @session.total_changes - @engine_total
      @engine_total = @session.total_changes
      StepResult.new(outcome, @session.changes, @session.last_insert_rowid, delta)
    end

    # Runs *sql* on both and returns the first difference, or nil.
    # Raises the engine's UnsupportedSQL.
    def step(sql : String, parameters : Array(Value) = [] of Value, ordered : Bool = true) : String?
      expected = c_step(sql, parameters)
      actual = engine_step(sql, parameters)
      Pair.difference(expected, actual, ordered)
    end

    def self.difference(expected : StepResult, actual : StepResult, ordered : Bool, compare_changes : Bool = true, compare_rowid : Bool = true) : String?
      if found = SQLiteQueryOracle.difference(expected.outcome, actual.outcome, ordered)
        return found
      end
      if compare_changes && expected.changes != actual.changes
        return "changes(): C #{expected.changes}, engine #{actual.changes}"
      end
      if compare_rowid && expected.last_insert_rowid != actual.last_insert_rowid
        return "last_insert_rowid(): C #{expected.last_insert_rowid}, engine #{actual.last_insert_rowid}"
      end
      if expected.total_changes != actual.total_changes
        return "total_changes() grew by: C #{expected.total_changes}, engine #{actual.total_changes}"
      end
      nil
    end

    # Replaces the engine's file with a copy of C's, after a statement the
    # engine skipped wrote to C's file, so later statements start from the
    # same rows. The session's foreign_keys setting carries over.
    def copy_c_file_to_engine : Nil
      foreign_keys = @session.foreign_keys?
      @session.database.close
      File.delete?("#{@engine_path}-journal")
      FileUtils.cp(@c_path, @engine_path)
      @session = Pair.open_session(@engine_path)
      @session.foreign_keys = foreign_keys
      @engine_total = 0_i64
      @changes_in_step = false
      @rowid_in_step = false
    end

    # True when C is outside a transaction (so both files hold committed
    # state that another connection can read).
    def autocommit? : Bool
      LibWriteOracle.get_autocommit(@c_connection.handle) != 0
    end

    # The difference between the two files as C reads them (schema rows
    # without root pages, every table's rows by rowid, sqlite_sequence),
    # or C's integrity_check failure on the engine's file; nil when equal.
    def file_difference : String?
      if Pair.wal?
        list = child_engine_dump
        return "integrity_check of the engine's file: #{list.first}" unless list.first == "ok"
        return compare_dumps(Pair.dump(@c_connection), list[1..])
      end
      engine_reader = SQLiteQueryOracle::Connection.new(@engine_path)
      begin
        integrity = engine_reader.query("PRAGMA integrity_check")
        unless integrity.error.nil? && integrity.list_of_rows == [["ok"] of Value]
          return "integrity_check of the engine's file: #{integrity.list_of_rows.first(5)} #{integrity.error}"
        end
        compare_dumps(Pair.dump(@c_connection), Pair.dump(engine_reader))
      ensure
        engine_reader.close
      end
    end

    private def compare_dumps(expected : Array(String), actual : Array(String)) : String?
      return if expected == actual
      expected.each_with_index do |line, index|
        return "file contents at line #{index}: C #{line}, engine #{actual[index]? || "(end)"}" if actual[index]? != line
      end
      "file contents: engine has #{actual.size - expected.size} more lines: #{actual[expected.size]?}"
    end

    # A logical dump through C: schema rows, then each table's rows, read
    # from main so a temp table of the same name (temp.sqlite_sequence after
    # an AUTOINCREMENT temp table) does not hide them.
    def self.dump(connection : SQLiteQueryOracle::Connection) : Array(String)
      lines = [] of String
      schema = connection.query("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
      schema.list_of_rows.each { |row| lines << "schema #{SQLiteQueryOracle.row_token(row)}" }
      schema.list_of_rows.each do |row|
        next unless row[0] == "table"
        name = row[1].as(String)
        sql = row[3].as?(String) || ""
        quoted = %("#{name.gsub('"', "\"\"")}")
        query = if sql.matches?(/without\s+rowid/i)
                  "SELECT * FROM main.#{quoted} ORDER BY 1"
                else
                  "SELECT rowid, * FROM main.#{quoted} ORDER BY rowid"
                end
        result = connection.query(query, row_limit: 1_000_000)
        lines << "rows of #{name}: #{result.error}" if result.error
        result.list_of_rows.each { |values| lines << "#{name} #{SQLiteQueryOracle.row_token(values)}" }
      end
      header = connection.query("PRAGMA user_version")
      lines << "user_version #{SQLiteQueryOracle.row_token(header.list_of_rows.first? || [] of Value)}"
      lines
    end
  end
end
