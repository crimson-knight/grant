require "spec"
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"
require "../../support/crystal_compiler"

# Two connections that conflict, forced step by step, give the same result
# code at every step on Grant's engine as on C SQLite: a write refused while
# another connection holds RESERVED (or the WAL write lock), a write from a
# stale WAL snapshot (SQLITE_BUSY_SNAPSHOT), busy_timeout's wait, and a
# COMMIT refused while another connection reads a rollback-journal database.
#
# Connections A and B are the helper program
# spec/support/sqlite_engine/busy_parity_helper.cr, built once for this file:
# either two processes, or one process with each connection on its own
# thread. Each step finishes before the next one is sent, so no answer
# depends on timing; the only measured times are busy_timeout's waits, with
# wide margins.
module BusyParity
  alias Engine = Grant::SQLite3::Engine

  HELPER_SOURCE = Path[__DIR__] / ".." / ".." / "support" / "sqlite_engine" / "busy_parity_helper.cr"
  # How long the spec waits for one answer before it calls the helper hung.
  ANSWER_TIMEOUT = 30.seconds
  # A step that C answers without calling the busy handler runs with
  # busy_timeout 2000, so an engine that waits instead is plainly slower.
  AT_ONCE = 0..999
  # busy_timeout 200: C's busy handler sleeps about 200 ms in all.
  ABOUT_200_MILLISECONDS = 150..1500

  class_property helper_path = ""

  def self.build_helper : Nil
    binary_path = File.tempname("grant_busy_parity_helper")
    arguments = ["build", "--no-color", "-Dpreview_mt", "-Dexecution_context", "-o", binary_path, HELPER_SOURCE.normalize.to_s]
    if link_flags = ENV["SPEC_GROUP_LINK_FLAGS"]?
      arguments << "--link-flags" << link_flags unless link_flags.empty?
    end
    output = IO::Memory.new
    status = Process.run(spec_crystal_compiler, arguments, output: output, error: output, chdir: File.expand_path("../../..", __DIR__))
    raise "building the busy parity helper failed:\n#{output}" unless status.success?
    self.helper_path = binary_path
  end

  def self.remove_helper : Nil
    File.delete?(helper_path)
    File.delete?("#{helper_path}.dwarf")
  end

  # One step's answer from the helper.
  record Answer, code : Int32, extended_code : Int32, milliseconds : Int32, message : String, rows : String do
    def self.parse(line : String) : self
      fields = line.split('\t', 6)
      new(fields[1].to_i, fields[2].to_i, fields[3].to_i, fields[4], fields[5])
    end

    def codes : String
      "#{code}/#{extended_code}"
    end
  end

  # Connections A and B to one database through one engine: two helper
  # processes, or one helper process with both connections.
  class ConnectionPair
    @list_of_helpers = [] of Process
    @helper_for = {} of Char => Process
    # Answers read while looking for the other connection's (one shared
    # helper only).
    @answers_waiting = Hash(Char, Deque(Answer)).new { |hash, name| hash[name] = Deque(Answer).new }

    def initialize(engine : Symbol, path : String, separate_processes : Bool)
      if separate_processes
        {'A', 'B'}.each { |name| @helper_for[name] = start_helper(engine, path, name.to_s) }
      else
        helper = start_helper(engine, path, "AB")
        @helper_for['A'] = @helper_for['B'] = helper
      end
    end

    private def start_helper(engine : Symbol, path : String, names : String) : Process
      helper = Process.new(BusyParity.helper_path, [engine.to_s, path, names],
        input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Inherit)
      helper.output.read_timeout = ANSWER_TIMEOUT
      @list_of_helpers << helper
      helper
    end

    # Sends *sql* to connection *name* without waiting for its answer.
    def start(name : Char, sql : String) : Nil
      input = @helper_for[name].input
      input.puts "#{name} #{sql}"
      input.flush
    end

    # The answer to the step connection *name* was last sent.
    def finish(name : Char) : Answer
      waiting = @answers_waiting[name]
      return waiting.shift unless waiting.empty?
      output = @helper_for[name].output
      loop do
        line = output.gets || raise "connection #{name}'s helper ended without an answer"
        answer = Answer.parse(line)
        return answer if line[0] == name
        @answers_waiting[line[0]] << answer
      end
    end

    def close : Nil
      @list_of_helpers.each(&.input.close)
      @list_of_helpers.each do |helper|
        status = helper.wait
        raise "a busy parity helper failed (#{status})" unless status.success?
      end
    end
  end

  # Runs a case's steps on a pair and writes down what each one answered.
  # Each step carries C's code (`"5/517"`: primary/extended), one for both
  # journal modes or a `{rollback journal, WAL}` pair; on C SQLite the
  # recorder checks it, so the transcript the engine must match is the one
  # the spec states.
  class Recorder
    getter transcript = [] of String

    def initialize(@pair : ConnectionPair, @engine : Symbol, @journal_mode : String)
    end

    # Runs *sql* on connection *name*. *wait* is the range of milliseconds
    # the step must take on either engine.
    def run(name : Char, sql : String, c_answers : String | {String, String}, wait : Range(Int32, Int32)? = nil) : Nil
      @pair.start(name, sql)
      finish(name, sql, c_answers, wait)
    end

    # Sends *sql* to connection *name*; `finish` reads its answer.
    def start(name : Char, sql : String) : Nil
      @pair.start(name, sql)
    end

    def finish(name : Char, sql : String, c_answers : String | {String, String}, wait : Range(Int32, Int32)? = nil) : Nil
      answer = @pair.finish(name)
      line = "#{name}: #{sql} -> #{answer.codes}"
      line += " #{answer.message}" unless answer.message.empty?
      line += " [#{answer.rows}]" unless answer.rows.empty?
      if wait
        line += wait.includes?(answer.milliseconds) ? " (#{wait} ms)" : " (#{answer.milliseconds} ms, not #{wait})"
      end
      @transcript << line
      if @engine == :libsqlite3
        expected = c_answers.is_a?(String) ? c_answers : (@journal_mode == "WAL" ? c_answers[1] : c_answers[0])
        {line, answer.codes}.should eq({line, expected})
      end
    end
  end

  # A case: the steps of connections A and B on a database whose table
  # `entries` holds one row, 'seed'.
  alias Case = Recorder ->

  def self.list_of_cases : Hash(String, Case)
    {
      "RESERVED held: a write and BEGIN IMMEDIATE refused at once" => Case.new do |steps|
        steps.run('A', "BEGIN IMMEDIATE", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.run('B', "INSERT INTO entries (label) VALUES ('b1')", "5/5")
        steps.run('B', "BEGIN IMMEDIATE", "5/5")
        steps.run('B', "BEGIN", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "INSERT INTO entries (label) VALUES ('b1')", "5/5")
        steps.run('B', "ROLLBACK", "0/0")
        steps.run('A', "COMMIT", "0/0")
        steps.run('B', "INSERT INTO entries (label) VALUES ('b2')", "0/0")
      end,
      # WAL: B's snapshot is older than A's commit (SQLITE_BUSY_SNAPSHOT).
      # Rollback journal: B's SHARED lock refuses A's COMMIT, and A's
      # RESERVED and PENDING locks refuse B's write; B's read transaction
      # is open, so C fails it at once without the busy handler.
      "a read transaction's write after another connection's commit (stale snapshot, or deadlock)" => Case.new do |steps|
        steps.run('B', "PRAGMA busy_timeout=2000", "0/0")
        steps.run('B', "BEGIN", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('A', "BEGIN IMMEDIATE", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.run('A', "COMMIT", {"5/5", "0/0"})
        steps.run('B', "INSERT INTO entries (label) VALUES ('b1')", {"5/5", "5/517"}, wait: AT_ONCE)
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "ROLLBACK", "0/0")
        steps.run('A', "COMMIT", {"0/0", "1/1"})
        steps.run('B', "INSERT INTO entries (label) VALUES ('b2')", "0/0")
      end,
      "busy_timeout 200: a write and BEGIN IMMEDIATE wait about 200 ms, then fail" => Case.new do |steps|
        steps.run('A', "BEGIN IMMEDIATE", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.run('B', "PRAGMA busy_timeout=200", "0/0")
        steps.run('B', "INSERT INTO entries (label) VALUES ('b1')", "5/5", wait: ABOUT_200_MILLISECONDS)
        steps.run('B', "BEGIN IMMEDIATE", "5/5", wait: ABOUT_200_MILLISECONDS)
        steps.run('A', "COMMIT", "0/0")
      end,
      "busy_timeout: a write waiting while the other connection commits then succeeds" => Case.new do |steps|
        steps.run('A', "PRAGMA busy_timeout=5000", "0/0")
        steps.run('A', "BEGIN IMMEDIATE", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.run('B', "PRAGMA busy_timeout=5000", "0/0")
        steps.start('B', "INSERT INTO entries (label) VALUES ('b1')")
        sleep 300.milliseconds
        steps.run('A', "COMMIT", "0/0")
        steps.finish('B', "INSERT INTO entries (label) VALUES ('b1')", "0/0")
      end,
      # Rollback journal: A's COMMIT cannot take EXCLUSIVE while B reads; A's
      # transaction stays open and commits once B has finished. WAL: readers
      # never stop a commit.
      "a read transaction and another connection's COMMIT" => Case.new do |steps|
        steps.run('B', "BEGIN", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('A', "BEGIN IMMEDIATE", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.run('A', "COMMIT", {"5/5", "0/0"})
        steps.run('A', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "COMMIT", "0/0")
        steps.run('A', "COMMIT", {"0/0", "1/1"})
      end,
      # A's transaction outgrows its ten-page cache. Rollback journal: a
      # cache spill needs EXCLUSIVE, so while B reads C skips the spill and
      # keeps the pages in memory, B still reads the committed rows, and A's
      # COMMIT waits for B; once B has gone, A's next spill takes EXCLUSIVE
      # and a new read by B is refused until A commits. WAL: nothing waits.
      # (cache_spill=1 is C's default; the macOS build sets it far higher.)
      "a reader holding SHARED while another connection's transaction spills its cache" => Case.new do |steps|
        rows = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 2000) " \
               "INSERT INTO entries (label) SELECT hex(zeroblob(100)) || x FROM n"
        steps.run('A', "PRAGMA cache_size=10", "0/0")
        steps.run('A', "PRAGMA cache_spill=1", "0/0")
        steps.run('B', "BEGIN", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('A', "BEGIN", "0/0")
        steps.run('A', rows, "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('A', "COMMIT", {"5/5", "0/0"})
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "COMMIT", "0/0")
        steps.run('A', "COMMIT", {"0/0", "1/1"})
        steps.run('A', "BEGIN", "0/0")
        steps.run('A', rows, "0/0")
        steps.run('B', "SELECT count(*) FROM entries", {"5/5", "0/0"})
        steps.run('A', "COMMIT", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
      end,
      "a deferred transaction that reads and writes after another connection's commit" => Case.new do |steps|
        steps.run('B', "BEGIN", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "INSERT INTO entries (label) VALUES ('b1')", "0/0")
        steps.run('B', "COMMIT", "0/0")
      end,
      # B has read nothing, so C calls the busy handler for its first write
      # and gives it the newest snapshot once A's commit lets it in.
      "a deferred transaction's first write waits for another connection's commit" => Case.new do |steps|
        steps.run('A', "PRAGMA busy_timeout=5000", "0/0")
        steps.run('B', "PRAGMA busy_timeout=5000", "0/0")
        steps.run('B', "BEGIN", "0/0")
        steps.run('A', "BEGIN IMMEDIATE", "0/0")
        steps.run('A', "INSERT INTO entries (label) VALUES ('a1')", "0/0")
        steps.start('B', "INSERT INTO entries (label) VALUES ('b1')")
        sleep 300.milliseconds
        steps.run('A', "COMMIT", "0/0")
        steps.finish('B', "INSERT INTO entries (label) VALUES ('b1')", "0/0")
        steps.run('B', "SELECT count(*) FROM entries", "0/0")
        steps.run('B', "COMMIT", "0/0")
      end,
    }
  end

  # Runs *steps* on a new database in *journal_mode* and returns the
  # transcript, ending with the table's rows once both connections closed.
  def self.transcript_of(steps : Case, engine : Symbol, journal_mode : String, separate_processes : Bool) : Array(String)
    path = File.tempname("grant_busy_parity", ".sqlite3")
    begin
      creator = open_with_libsqlite3(path)
      code = creator.exec("PRAGMA journal_mode=#{journal_mode}; CREATE TABLE entries (id INTEGER PRIMARY KEY, label TEXT); INSERT INTO entries (label) VALUES ('seed')")
      raise "setup failed (#{code}): #{creator.error_message}" unless code == Engine::OK_CODE
      creator.close
      pair = ConnectionPair.new(engine, path, separate_processes)
      recorder = Recorder.new(pair, engine, journal_mode)
      begin
        steps.call(recorder)
      ensure
        pair.close
      end
      recorder.transcript << "rows: #{list_of_labels(path).join(",")}"
    ensure
      {path, "#{path}-wal", "#{path}-shm", "#{path}-journal"}.each { |file| File.delete?(file) }
    end
  end

  def self.open_with_libsqlite3(path : String) : Engine::Database
    code, database = Engine::LibSQLite3Engine.new.open(path)
    raise "open failed (#{code})" unless code == Engine::OK_CODE
    database
  end

  def self.list_of_labels(path : String) : Array(String)
    database = open_with_libsqlite3(path)
    code, statement = database.prepare("SELECT label FROM entries ORDER BY id")
    raise "reading the rows failed (#{code}): #{database.error_message}" unless code == Engine::OK_CODE
    list_of_labels = [] of String
    while statement.step == Engine::ROW_CODE
      list_of_labels << statement.column_text(0)
    end
    statement.finalize_statement
    database.close
    list_of_labels
  end
end

describe "Grant::SQLiteEngine busy results between two connections" do
  before_all { BusyParity.build_helper }
  after_all { BusyParity.remove_helper }

  {"DELETE", "WAL"}.each do |journal_mode|
    {true, false}.each do |separate_processes|
      context "in #{journal_mode} mode, #{separate_processes ? "connections in two processes" : "connections on two threads of one process"}" do
        BusyParity.list_of_cases.each do |description, steps|
          it "answers each step as C SQLite does: #{description}" do
            c_transcript = BusyParity.transcript_of(steps, :libsqlite3, journal_mode, separate_processes)
            engine_transcript = BusyParity.transcript_of(steps, :grant, journal_mode, separate_processes)
            engine_transcript.should eq c_transcript
          end
        end
      end
    end
  end
end
