require "spec"
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"

# Lock waits between processes, the same on Grant's engine as on C SQLite:
# opening a WAL database a killed writer left, and writers that take turns.
# The spec program runs itself again as each helper process.
module LockWaitProcesses
  alias Engine = Grant::SQLite3::Engine

  LIST_OF_ENGINES = {:libsqlite3, :grant}
  ROLE_VARIABLE   = "GRANT_LOCK_WAIT_SPEC_ROLE"
  ENGINE_VARIABLE = "GRANT_LOCK_WAIT_SPEC_ENGINE"
  PATH_VARIABLE   = "GRANT_LOCK_WAIT_SPEC_PATH"
  # The rows each "inserter" helper adds, one transaction each.
  INSERTS_EACH = 40

  def self.engine_named(name : Symbol) : Engine
    name == :grant ? Engine::GrantEngine.new : Engine::LibSQLite3Engine.new
  end

  # Runs the helper *role* and leaves the process: 0 when every statement
  # succeeded, with what happened on standard output.
  def self.run_helper(role : String) : NoReturn
    engine = engine_named(ENV[ENGINE_VARIABLE] == "grant" ? :grant : :libsqlite3)
    code, database = engine.open(ENV[PATH_VARIABLE])
    leave("open #{code} #{database.error_message}") unless code == Engine::OK_CODE
    code = database.exec("PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;")
    leave("pragmas #{code} #{database.error_message}") unless code == Engine::OK_CODE
    case role
    when "writer_to_kill"
      number = 0
      loop do
        database.exec("BEGIN IMMEDIATE; INSERT INTO entries (label, filler) VALUES ('row #{number}', randomblob(2000)); COMMIT;")
        number += 1
      end
    when "inserter"
      INSERTS_EACH.times do |number|
        code = database.exec("INSERT INTO entries (label, filler) VALUES ('#{Process.pid} #{number}', randomblob(200))")
        leave("insert #{number}: #{code} #{database.error_message}") unless code == Engine::OK_CODE
      end
      leave("rows #{INSERTS_EACH}", 0)
    else
      code, statement = database.prepare("SELECT count(*) FROM entries")
      leave("prepare #{code} #{database.error_message}") unless code == Engine::OK_CODE
      code = statement.step
      leave("step #{code} #{database.error_message}") unless code == Engine::ROW_CODE
      leave("rows #{statement.column_int64(0)}", 0)
    end
  end

  def self.leave(message : String, status : Int32 = 1) : NoReturn
    STDOUT.puts message
    STDOUT.flush
    LibC._exit(status)
  end

  def self.start_helper(role : String, engine : Symbol, path : String) : Process
    program = Process.executable_path || raise "the spec program has no path"
    environment = {ROLE_VARIABLE => role, ENGINE_VARIABLE => engine.to_s, PATH_VARIABLE => path}
    Process.new(program, env: environment, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
  end

  # What each helper printed, once all have finished.
  def self.answers_of(list_of_helpers : Array(Process)) : Array(String)
    list_of_helpers.map do |helper|
      answer = (helper.output.gets_to_end + helper.error.gets_to_end).strip
      helper.wait
      answer
    end
  end

  # Yields the path of a new database with the table the helpers use, in
  # *journal_mode*, then removes its files.
  def self.with_database(journal_mode : String, & : String ->) : Nil
    path = File.tempname("grant_lock_wait_processes", ".sqlite3")
    begin
      code, creator = engine_named(:libsqlite3).open(path)
      raise "open failed (#{code})" unless code == Engine::OK_CODE
      code = creator.exec("PRAGMA journal_mode=#{journal_mode}; CREATE TABLE entries (id INTEGER PRIMARY KEY, label TEXT, filler BLOB)")
      raise "setup failed (#{code}): #{creator.error_message}" unless code == Engine::OK_CODE
      creator.close
      yield path
    ensure
      {path, "#{path}-wal", "#{path}-shm", "#{path}-journal"}.each { |file| File.delete(file) if File.exists?(file) }
    end
  end

  def self.row_count(path : String) : Int64
    code, database = engine_named(:libsqlite3).open(path)
    raise "open failed (#{code})" unless code == Engine::OK_CODE
    code, statement = database.prepare("SELECT count(*) FROM entries")
    raise "count failed (#{code}): #{database.error_message}" unless code == Engine::OK_CODE
    statement.step
    count = statement.column_int64(0)
    statement.finalize_statement
    database.close
    count
  end
end

if helper_role = ENV[LockWaitProcesses::ROLE_VARIABLE]?
  LockWaitProcesses.run_helper(helper_role)
end

describe "Grant::SQLiteEngine lock waits between processes" do
  it "lets four processes open a WAL database at once after a writer was killed, each waiting out the recovery" do
    LockWaitProcesses::LIST_OF_ENGINES.each do |engine|
      4.times do |round|
        LockWaitProcesses.with_database("WAL") do |path|
          writer = LockWaitProcesses.start_helper("writer_to_kill", :grant, path)
          sleep 400.milliseconds
          writer.signal(Signal::KILL)
          writer.wait
          list_of_readers = Array.new(4) { LockWaitProcesses.start_helper("reader", engine, path) }
          LockWaitProcesses.answers_of(list_of_readers).each do |answer|
            {engine, round, answer.starts_with?("rows ") ? "rows" : answer}.should eq({engine, round, "rows"})
          end
        end
      end
    end
  end

  {"DELETE", "WAL"}.each do |journal_mode|
    it "lets three processes insert at once in #{journal_mode} mode, every statement waiting its turn" do
      LockWaitProcesses::LIST_OF_ENGINES.each do |engine|
        LockWaitProcesses.with_database(journal_mode) do |path|
          list_of_inserters = Array.new(3) { LockWaitProcesses.start_helper("inserter", engine, path) }
          LockWaitProcesses.answers_of(list_of_inserters).each do |answer|
            {engine, answer}.should eq({engine, "rows #{LockWaitProcesses::INSERTS_EACH}"})
          end
          LockWaitProcesses.row_count(path).should eq 3 * LockWaitProcesses::INSERTS_EACH
        end
      end
    end

    it "lets engine and C processes insert at once in #{journal_mode} mode" do
      LockWaitProcesses.with_database(journal_mode) do |path|
        list_of_inserters = {:grant, :libsqlite3, :grant, :libsqlite3}.map { |engine| LockWaitProcesses.start_helper("inserter", engine, path) }.to_a
        LockWaitProcesses.answers_of(list_of_inserters).each do |answer|
          answer.should eq "rows #{LockWaitProcesses::INSERTS_EACH}"
        end
        LockWaitProcesses.row_count(path).should eq 4 * LockWaitProcesses::INSERTS_EACH
      end
    end
  end
end
