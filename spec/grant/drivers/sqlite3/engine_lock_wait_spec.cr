{% skip_file unless (env("CURRENT_ADAPTER") || "sqlite") == "sqlite" %}

require "../../../spec_helper"

# Where a connection waits for another connection's lock (its busy handler,
# sqlite3_busy_timeout) and where it fails at once: the same on Grant's
# engine as on C SQLite 3.51.0, whose answers are the expectations here.
module EngineLockWaitSpec
  alias Engine = Grant::SQLite3::Engine

  LIST_OF_ENGINES = {:libsqlite3, :grant}
  # The waiting connection's busy_timeout.
  TIMEOUT = 300.milliseconds
  # A statement that came back sooner than this did not wait; one that
  # took at least WAITED did.
  AT_ONCE = 150.milliseconds
  WAITED  = 280.milliseconds

  record Outcome, code : Int32, waited : Bool, list_of_rows : Array(Array(Int64)) do
    def at_once? : Bool
      !waited
    end
  end

  def self.open(engine : Symbol, path : String) : Engine::Database
    code, database = Engine.named(engine).open(path)
    raise "open failed (#{code}): #{database.error_message}" unless code == Engine::OK_CODE
    database
  end

  def self.run(database : Engine::Database, sql : String) : Nil
    code = database.exec(sql)
    raise "#{sql}: #{code} #{database.error_message}" unless code == Engine::OK_CODE
  end

  # Runs one statement and reports its result code (0 when it finished),
  # its integer rows, and whether it waited out the busy timeout.
  def self.attempt(database : Engine::Database, sql : String) : Outcome
    list_of_rows = [] of Array(Int64)
    started = Time.instant
    code, statement = database.prepare(sql)
    if code == Engine::OK_CODE
      loop do
        code = statement.step
        break unless code == Engine::ROW_CODE
        list_of_rows << (0...statement.column_count).map { |column| statement.column_int64(column) }
      end
      statement.finalize_statement
      code = Engine::OK_CODE if code == Engine::DONE_CODE
    end
    elapsed = Time.instant - started
    raise "#{sql} took #{elapsed.total_milliseconds} ms: neither at once nor a full wait" if elapsed > AT_ONCE && elapsed < WAITED
    Outcome.new(code, elapsed >= WAITED, list_of_rows)
  end

  # Yields a holder and a waiter connection (busy_timeout TIMEOUT) to one
  # database in *journal_mode*, once per engine.
  def self.each_pair(journal_mode : String, & : Engine::Database, Engine::Database, Symbol ->) : Nil
    LIST_OF_ENGINES.each do |engine|
      path = File.tempname("grant_engine_lock_wait", ".sqlite3")
      holder = open(engine, path)
      waiter = open(engine, path)
      begin
        run(holder, "PRAGMA journal_mode=#{journal_mode}")
        run(holder, "CREATE TABLE entries (id INTEGER PRIMARY KEY, label TEXT); INSERT INTO entries (label) VALUES ('first')")
        run(waiter, "PRAGMA busy_timeout=#{TIMEOUT.total_milliseconds.to_i}")
        run(waiter, "SELECT count(*) FROM entries")
        yield holder, waiter, engine
      ensure
        waiter.exec("ROLLBACK")
        holder.exec("ROLLBACK")
        waiter.close
        holder.close
        {path, "#{path}-wal", "#{path}-shm", "#{path}-journal"}.each { |file| File.delete(file) if File.exists?(file) }
      end
    end
  end
end

describe "Grant::SQLite3 engine lock waits" do
  describe "a PRAGMA that reads no file" do
    it "runs at once while another connection holds the database exclusively, as C compiles it without the schema" do
      EngineLockWaitSpec.each_pair("DELETE") do |holder, _waiter, engine|
        EngineLockWaitSpec.run(holder, "BEGIN EXCLUSIVE")
        # A connection whose busy_timeout is still 0 cannot wait for anything.
        newcomer = EngineLockWaitSpec.open(engine, holder_path(holder))
        begin
          EngineLockWaitSpec.attempt(newcomer, "PRAGMA busy_timeout=300").should eq EngineLockWaitSpec::Outcome.new(0, false, [[300_i64]])
          EngineLockWaitSpec.attempt(newcomer, "PRAGMA main.busy_timeout").should eq EngineLockWaitSpec::Outcome.new(0, false, [[300_i64]])
          EngineLockWaitSpec.attempt(newcomer, "PRAGMA foreign_keys=ON").code.should eq 0
          EngineLockWaitSpec.attempt(newcomer, "PRAGMA foreign_keys").should eq EngineLockWaitSpec::Outcome.new(0, false, [[1_i64]])
          # PragFlg_NeedSchema: compiling it reads the schema, and waits.
          waited = EngineLockWaitSpec.attempt(newcomer, "PRAGMA synchronous=FULL")
          {engine, waited.code, waited.waited}.should eq({engine, 5, true})
          # A header value is read when the statement runs, and waits.
          waited = EngineLockWaitSpec.attempt(newcomer, "PRAGMA user_version")
          {engine, waited.code, waited.waited}.should eq({engine, 5, true})
          # The connection opened while the file was held reads it once it is free.
          EngineLockWaitSpec.run(holder, "ROLLBACK")
          outcome = EngineLockWaitSpec.attempt(newcomer, "SELECT count(*) FROM entries")
          {engine, outcome}.should eq({engine, EngineLockWaitSpec::Outcome.new(0, false, [[1_i64]])})
        ensure
          newcomer.close
        end
      end
    end

    it "tells a PRAGMA's name without the parser" do
      names = Grant::SQLiteEngine::Query::PragmaFileAccess
      names.name_in("PRAGMA busy_timeout=5000").should eq "busy_timeout"
      names.name_in("  pragma Main . Synchronous = FULL;").should eq "synchronous"
      names.name_in("PRAGMA wal_checkpoint(TRUNCATE)").should eq "wal_checkpoint"
      names.name_in("PRAGMATIC x").should be_nil
      names.name_in("SELECT 1").should be_nil
      names.name_in("PRAGMA \"busy_timeout\"").should be_nil
      names.compile_reads_schema?("busy_timeout").should be_false
      names.compile_reads_schema?("journal_mode").should be_true
      names.run_reads_file?("fullfsync").should be_false
      names.run_reads_file?("user_version").should be_true
    end
  end

  describe "with a rollback journal" do
    it "waits for a writer's RESERVED lock before a transaction has read, and fails at once after" do
      EngineLockWaitSpec.each_pair("DELETE") do |holder, waiter, engine|
        EngineLockWaitSpec.run(holder, "BEGIN IMMEDIATE; INSERT INTO entries (label) VALUES ('held')")
        outcome = EngineLockWaitSpec.attempt(waiter, "SELECT count(*) FROM entries")
        {engine, "read", outcome}.should eq({engine, "read", EngineLockWaitSpec::Outcome.new(0, false, [[1_i64]])})
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('autocommit')")
        {engine, "autocommit", outcome.code, outcome.waited}.should eq({engine, "autocommit", 5, true})
        outcome = EngineLockWaitSpec.attempt(waiter, "BEGIN IMMEDIATE")
        {engine, "immediate", outcome.code, outcome.waited}.should eq({engine, "immediate", 5, true})
        EngineLockWaitSpec.run(waiter, "BEGIN")
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('deferred first write')")
        {engine, "deferred", outcome.code, outcome.waited}.should eq({engine, "deferred", 5, true})
        EngineLockWaitSpec.run(waiter, "ROLLBACK; BEGIN; SELECT count(*) FROM entries")
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('after a read')")
        {engine, "after a read", outcome.code, outcome.waited}.should eq({engine, "after a read", 5, false})
      end
    end

    it "waits for an EXCLUSIVE lock to read, and for readers to commit" do
      EngineLockWaitSpec.each_pair("DELETE") do |holder, waiter, engine|
        EngineLockWaitSpec.run(holder, "BEGIN EXCLUSIVE")
        outcome = EngineLockWaitSpec.attempt(waiter, "SELECT count(*) FROM entries")
        {engine, "read", outcome.code, outcome.waited}.should eq({engine, "read", 5, true})
        EngineLockWaitSpec.run(holder, "ROLLBACK; BEGIN; SELECT count(*) FROM entries")
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('needs EXCLUSIVE')")
        {engine, "commit", outcome.code, outcome.waited}.should eq({engine, "commit", 5, true})
        EngineLockWaitSpec.run(waiter, "BEGIN IMMEDIATE; INSERT INTO entries (label) VALUES ('kept')")
        outcome = EngineLockWaitSpec.attempt(waiter, "COMMIT")
        {engine, "COMMIT", outcome.code, outcome.waited}.should eq({engine, "COMMIT", 5, true})
        # The refused COMMIT left the transaction open: it commits once the reader is gone.
        EngineLockWaitSpec.run(holder, "ROLLBACK")
        outcome = EngineLockWaitSpec.attempt(waiter, "COMMIT")
        {engine, "COMMIT again", outcome.code, outcome.waited}.should eq({engine, "COMMIT again", 0, false})
        outcome = EngineLockWaitSpec.attempt(holder, "SELECT count(*) FROM entries")
        {engine, outcome.list_of_rows}.should eq({engine, [[2_i64]]})
      end
    end

    it "fails a write at once while another statement of the connection is still reading" do
      {"DELETE", "WAL"}.each do |journal_mode|
        EngineLockWaitSpec.each_pair(journal_mode) do |holder, waiter, engine|
          EngineLockWaitSpec.run(holder, "INSERT INTO entries (label) VALUES ('second')")
          code, reading = waiter.prepare("SELECT id FROM entries ORDER BY id")
          code.should eq 0
          reading.step.should eq Grant::SQLite3::Engine::ROW_CODE
          EngineLockWaitSpec.run(holder, "BEGIN IMMEDIATE; INSERT INTO entries (label) VALUES ('held')")
          begin
            outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('while reading')")
            {engine, journal_mode, outcome.code, outcome.waited}.should eq({engine, journal_mode, 5, false})
          ensure
            reading.finalize_statement
          end
          # With the read finished the same write waits.
          outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('after reading')")
          {engine, journal_mode, outcome.code, outcome.waited}.should eq({engine, journal_mode, 5, true})
        end
      end
    end

    it "lets a transaction whose first write was refused wait again" do
      {"DELETE", "WAL"}.each do |journal_mode|
        EngineLockWaitSpec.each_pair(journal_mode) do |holder, waiter, engine|
          EngineLockWaitSpec.run(holder, "BEGIN IMMEDIATE; INSERT INTO entries (label) VALUES ('held')")
          EngineLockWaitSpec.run(waiter, "BEGIN")
          2.times do |try|
            outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('deferred first write')")
            {engine, journal_mode, try, outcome.code, outcome.waited}.should eq({engine, journal_mode, try, 5, true})
          end
          EngineLockWaitSpec.run(holder, "COMMIT")
          outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('deferred first write')")
          {engine, journal_mode, outcome.code, outcome.waited}.should eq({engine, journal_mode, 0, false})
          EngineLockWaitSpec.run(waiter, "COMMIT")
          outcome = EngineLockWaitSpec.attempt(holder, "SELECT count(*) FROM entries")
          {engine, journal_mode, outcome.list_of_rows}.should eq({engine, journal_mode, [[3_i64]]})
        end
      end
    end
  end

  describe "in WAL mode" do
    it "waits for the WRITE lock before a transaction has read, and fails at once after" do
      EngineLockWaitSpec.each_pair("WAL") do |holder, waiter, engine|
        EngineLockWaitSpec.run(holder, "BEGIN IMMEDIATE; INSERT INTO entries (label) VALUES ('held')")
        outcome = EngineLockWaitSpec.attempt(waiter, "SELECT count(*) FROM entries")
        {engine, "read", outcome}.should eq({engine, "read", EngineLockWaitSpec::Outcome.new(0, false, [[1_i64]])})
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('autocommit')")
        {engine, "autocommit", outcome.code, outcome.waited}.should eq({engine, "autocommit", 5, true})
        outcome = EngineLockWaitSpec.attempt(waiter, "BEGIN IMMEDIATE")
        {engine, "immediate", outcome.code, outcome.waited}.should eq({engine, "immediate", 5, true})
        EngineLockWaitSpec.run(waiter, "BEGIN")
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('deferred first write')")
        {engine, "deferred", outcome.code, outcome.waited}.should eq({engine, "deferred", 5, true})
        EngineLockWaitSpec.run(waiter, "ROLLBACK; BEGIN; SELECT count(*) FROM entries")
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('after a read')")
        {engine, "after a read", outcome.code, outcome.waited}.should eq({engine, "after a read", 5, false})
      end
    end

    it "fails a write at once when another connection committed after the transaction's snapshot" do
      EngineLockWaitSpec.each_pair("WAL") do |holder, waiter, engine|
        EngineLockWaitSpec.run(waiter, "BEGIN; SELECT count(*) FROM entries")
        EngineLockWaitSpec.run(holder, "INSERT INTO entries (label) VALUES ('newer')")
        outcome = EngineLockWaitSpec.attempt(waiter, "INSERT INTO entries (label) VALUES ('stale snapshot')")
        {engine, outcome.code, outcome.waited}.should eq({engine, 5, false})
      end
    end

    it "checkpoints around a writer: PASSIVE at once, FULL after waiting for the WRITE lock" do
      EngineLockWaitSpec.each_pair("WAL") do |holder, waiter, engine|
        EngineLockWaitSpec.run(holder, "BEGIN IMMEDIATE; INSERT INTO entries (label) VALUES ('held')")
        outcome = EngineLockWaitSpec.attempt(waiter, "PRAGMA wal_checkpoint(PASSIVE)")
        {engine, "passive", outcome.code, outcome.waited, outcome.list_of_rows.map(&.first)}.should eq({engine, "passive", 0, false, [0_i64]})
        {"FULL", "RESTART", "TRUNCATE"}.each do |mode|
          outcome = EngineLockWaitSpec.attempt(waiter, "PRAGMA wal_checkpoint(#{mode})")
          {engine, mode, outcome.code, outcome.waited, outcome.list_of_rows.map(&.first)}.should eq({engine, mode, 0, true, [1_i64]})
        end
      end
    end

    it "waits in a FULL checkpoint for a reader of an older snapshot" do
      EngineLockWaitSpec.each_pair("WAL") do |holder, waiter, engine|
        EngineLockWaitSpec.run(holder, "BEGIN; SELECT count(*) FROM entries")
        EngineLockWaitSpec.run(waiter, "INSERT INTO entries (label) VALUES ('newer')")
        outcome = EngineLockWaitSpec.attempt(waiter, "PRAGMA wal_checkpoint(PASSIVE)")
        {engine, "passive", outcome.code, outcome.waited, outcome.list_of_rows.map(&.first)}.should eq({engine, "passive", 0, false, [0_i64]})
        outcome = EngineLockWaitSpec.attempt(waiter, "PRAGMA wal_checkpoint(FULL)")
        {engine, "full", outcome.code, outcome.waited, outcome.list_of_rows.map(&.first)}.should eq({engine, "full", 0, true, [1_i64]})
      end
    end

    it "waits in a RESTART or TRUNCATE checkpoint for a reader of the newest snapshot, which FULL leaves alone" do
      EngineLockWaitSpec.each_pair("WAL") do |holder, waiter, engine|
        EngineLockWaitSpec.run(waiter, "INSERT INTO entries (label) VALUES ('newer')")
        EngineLockWaitSpec.run(holder, "BEGIN; SELECT count(*) FROM entries")
        outcome = EngineLockWaitSpec.attempt(waiter, "PRAGMA wal_checkpoint(FULL)")
        {engine, "full", outcome.code, outcome.waited, outcome.list_of_rows.map(&.first)}.should eq({engine, "full", 0, false, [0_i64]})
        {"RESTART", "TRUNCATE"}.each do |mode|
          outcome = EngineLockWaitSpec.attempt(waiter, "PRAGMA wal_checkpoint(#{mode})")
          {engine, mode, outcome.code, outcome.waited, outcome.list_of_rows.map(&.first)}.should eq({engine, mode, 0, true, [1_i64]})
        end
      end
    end
  end
end

# The file a connection of the pair has open (PRAGMA database_list).
private def holder_path(database : Grant::SQLite3::Engine::Database) : String
  code, statement = database.prepare("PRAGMA database_list")
  raise "database_list: #{code}" unless code == Grant::SQLite3::Engine::OK_CODE
  statement.step
  path = statement.column_text(2)
  statement.finalize_statement
  path
end
