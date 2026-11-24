require "spec"
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"
require "../../support/crystal_compiler"

# Lock waits between processes, the same on Grant's engine as on C SQLite:
# opening a WAL database a killed writer left, and writers that take turns.
# Each process is the helper program spec/support/sqlite_engine/lock_wait_helper.cr,
# built once for this file. SPEC_GROUP_LINK_FLAGS (the link flags
# scripts/spec-groups.sh passes on) links the helper to the same pinned
# libsqlite3 as the specs; without it the helper links the system's.
module LockWaitProcesses
  alias Engine = Grant::SQLite3::Engine

  LIST_OF_ENGINES = {:libsqlite3, :grant}
  # The rows each "inserter" helper adds, one transaction each.
  INSERTS_EACH  = 40
  HELPER_SOURCE = Path[__DIR__] / ".." / ".." / "support" / "sqlite_engine" / "lock_wait_helper.cr"

  class_property helper_path = ""

  def self.engine_named(name : Symbol) : Engine
    name == :grant ? Engine::GrantEngine.new : Engine::LibSQLite3Engine.new
  end

  def self.build_helper : Nil
    binary_path = File.tempname("grant_lock_wait_helper")
    arguments = ["build", "--no-color", "-o", binary_path, HELPER_SOURCE.normalize.to_s]
    if link_flags = ENV["SPEC_GROUP_LINK_FLAGS"]?
      arguments << "--link-flags" << link_flags unless link_flags.empty?
    end
    output = IO::Memory.new
    status = Process.run(spec_crystal_compiler, arguments, output: output, error: output, chdir: File.expand_path("../../..", __DIR__))
    raise "building the lock wait helper failed:\n#{output}" unless status.success?
    self.helper_path = binary_path
  end

  def self.remove_helper : Nil
    File.delete?(helper_path)
    File.delete?("#{helper_path}.dwarf")
  end

  def self.start_helper(role : String, engine : Symbol, path : String) : Process
    Process.new(helper_path, [role, engine.to_s, path], output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
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

describe "Grant::SQLiteEngine lock waits between processes" do
  before_all { LockWaitProcesses.build_helper }
  after_all { LockWaitProcesses.remove_helper }

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

  # C itself refuses one of these now and then (SQLITE_BUSY from a lock it
  # takes without the busy handler while the journal mode changes), so the
  # expectation is what both engines keep: a refused process says "database
  # is locked" and adds nothing, and the others' rows are all there.
  it "turns a rollback-journal database to WAL from four processes at once" do
    LockWaitProcesses::LIST_OF_ENGINES.each do |engine|
      3.times do |round|
        LockWaitProcesses.with_database("DELETE") do |path|
          list_of_switchers = Array.new(4) { LockWaitProcesses.start_helper("wal_switcher", engine, path) }
          list_of_answers = LockWaitProcesses.answers_of(list_of_switchers)
          list_of_answers.each do |answer|
            {engine, round, answer == "switch: 5 database is locked" ? "rows 1" : answer}.should eq({engine, round, "rows 1"})
          end
          succeeded = list_of_answers.count("rows 1")
          succeeded.should be >= 1
          LockWaitProcesses.row_count(path).should eq succeeded
          # Header bytes 18 and 19 say WAL (fileformat2.html §1.3.5).
          File.open(path, &.read_at(18, 2, &.getb_to_end)).should eq Bytes[2, 2]
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
