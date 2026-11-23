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
    getter c_path : String
    getter engine_path : String
    getter c_connection : SQLiteQueryOracle::Connection
    getter session : Grant::SQLiteEngine::Query::Session

    def initialize(@directory : String, name : String = "db")
      Dir.mkdir_p(@directory)
      @c_path = File.join(@directory, "#{name}-c.db")
      @engine_path = File.join(@directory, "#{name}-engine.db")
      [@c_path, @engine_path].each do |path|
        File.delete?(path)
        File.delete?("#{path}-journal")
      end
      @c_connection = SQLiteQueryOracle::Connection.new(@c_path)
      @session = Pair.open_session(@engine_path)
    end

    def self.open_session(path : String) : Grant::SQLiteEngine::Query::Session
      pager = Grant::SQLiteEngine::Pager.open_read_write(Grant::SQLiteEngine::PosixFileSystem.new, path)
      Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.new(pager, File.realpath(path)))
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

    def engine_step(sql : String, parameters : Array(Value) = [] of Value) : StepResult
      outcome = SQLiteQueryOracle.engine_query(@session, sql, parameters)
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

    def self.difference(expected : StepResult, actual : StepResult, ordered : Bool) : String?
      if found = SQLiteQueryOracle.difference(expected.outcome, actual.outcome, ordered)
        return found
      end
      return "changes(): C #{expected.changes}, engine #{actual.changes}" if expected.changes != actual.changes
      if expected.last_insert_rowid != actual.last_insert_rowid
        return "last_insert_rowid(): C #{expected.last_insert_rowid}, engine #{actual.last_insert_rowid}"
      end
      if expected.total_changes != actual.total_changes
        return "total_changes() grew by: C #{expected.total_changes}, engine #{actual.total_changes}"
      end
      nil
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
      engine_reader = SQLiteQueryOracle::Connection.new(@engine_path)
      begin
        integrity = engine_reader.query("PRAGMA integrity_check")
        unless integrity.error.nil? && integrity.list_of_rows == [["ok"] of Value]
          return "integrity_check of the engine's file: #{integrity.list_of_rows.first(5)} #{integrity.error}"
        end
        expected = Pair.dump(@c_connection)
        actual = Pair.dump(engine_reader)
        return if expected == actual
        expected.each_with_index do |line, index|
          return "file contents at line #{index}: C #{line}, engine #{actual[index]? || "(end)"}" if actual[index]? != line
        end
        "file contents: engine has #{actual.size - expected.size} more lines: #{actual[expected.size]?}"
      ensure
        engine_reader.close
      end
    end

    # A logical dump through C: schema rows, then each table's rows.
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
                  "SELECT * FROM #{quoted} ORDER BY 1"
                else
                  "SELECT rowid, * FROM #{quoted} ORDER BY rowid"
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
