require "spec"
require "file_utils"
require "../../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/lib_sqlite3_engine"
require "../../../support/sqlite_engine/counting_file_system"

# Runs statements through Grant's engine and libsqlite3, each in one
# connection of its own, and compares result code, column names and rows.
private module DurabilityDifferential
  alias Engine = Grant::SQLite3::Engine

  def self.outcome(database : Engine::Database, sql : String) : String
    code, statement = database.prepare(sql)
    return "code=#{code} #{database.error_message}" unless code == Engine::OK_CODE
    list_of_columns = (0...statement.column_count).map { |index| statement.column_name(index) }
    list_of_rows = [] of Array(String)
    step = Engine::ROW_CODE
    loop do
      step = statement.step
      break unless step == Engine::ROW_CODE
      list_of_rows << (0...statement.column_count).map do |column|
        case statement.column_type(column)
        when Grant::SQLite3::Type::INTEGER then "i:#{statement.column_int64(column)}"
        when Grant::SQLite3::Type::NULL    then "null"
        else                                    "t:#{statement.column_text(column)}"
        end
      end
    end
    message = step == Engine::DONE_CODE ? "" : database.error_message
    statement.finalize_statement
    "code=#{step} #{message} #{list_of_columns} #{list_of_rows}"
  end

  def self.outcomes(engine : Engine, path : String, list_of_statements : Array(String)) : Array(String)
    FileUtils.rm_rf(path)
    code, database = engine.open(path)
    raise "open failed (#{code})" unless code == Engine::OK_CODE
    begin
      list_of_statements.map { |sql| "#{sql} => #{outcome(database, sql)}" }
    ensure
      database.close
    end
  end

  def self.differences(list_of_statements : Array(String)) : Array(String)
    directory = File.tempname("durability-pragmas")
    Dir.mkdir_p(directory)
    begin
      expected = outcomes(Engine::LibSQLite3Engine.new, File.join(directory, "c.db"), list_of_statements)
      actual = outcomes(Engine::GrantEngine.new, File.join(directory, "grant.db"), list_of_statements)
      expected.zip(actual).compact_map { |c, grant| c == grant ? nil : "C:     #{c}\n      Grant: #{grant}" }
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  NAMES  = %w[fullfsync checkpoint_fullfsync FullFsync CHECKPOINT_FULLFSYNC]
  VALUES = %w[0 1 2 on off ON Off yes no YES true false TRUE FALSE full extra normal 00 01 007 255 256 257 512 1024 65536
    4294967296 2147483647 2147483648 99999999999 1.5 0.9 1e3 0x1 0x100 0x0 0xff -1 -0 +1 +0 'on' 'off' "yes" 'true' 'x'
    '' '1' '0' '256' maybe o tru onn]
  READS = ["PRAGMA fullfsync", "PRAGMA checkpoint_fullfsync", "PRAGMA synchronous", "SELECT * FROM pragma_fullfsync",
           "SELECT * FROM pragma_checkpoint_fullfsync", "PRAGMA main.fullfsync", "PRAGMA main.checkpoint_fullfsync",
           "SELECT fullfsync, checkpoint_fullfsync, synchronous FROM pragma_fullfsync, pragma_checkpoint_fullfsync(), pragma_synchronous"]
  OTHERS = ["BEGIN", "COMMIT", "ROLLBACK", "CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, body TEXT)",
            "INSERT INTO notes(body) VALUES ('kept')", "PRAGMA journal_mode=WAL", "PRAGMA journal_mode=DELETE",
            "SELECT count(*) FROM notes", "ATTACH ':memory:' AS side",
            "DETACH side"]

  # One random statement: a setting of either flag in one of C's three
  # spellings, a read, or a statement around them.
  def self.random_statement(random : Random) : String
    case random.rand(10)
    when 0..4
      name = NAMES.sample(random)
      name = "#{%w[main temp MAIN].sample(random)}.#{name}" if random.rand(6) == 0
      value = VALUES.sample(random)
      random.rand(4) == 0 ? "PRAGMA #{name}(#{value})" : "PRAGMA #{name}#{[" = ", "="].sample(random)}#{value}"
    when 5..7 then READS.sample(random)
    else           OTHERS.sample(random)
    end
  end
end

# Runs SQL in the engine over a file system that records each sync.
private class CountedConnection
  getter file_system = SQLiteEngineCountingFileSystem.new
  @engine_database : Grant::SQLiteEngine::Database
  @database : Grant::SQLite3::Engine::GrantEngine::Database

  def initialize
    @engine_database = Grant::SQLiteEngine::Database.open("counted.db", read_write: true, file_system: @file_system)
    @database = Grant::SQLite3::Engine::GrantEngine::Database.new(@engine_database)
  end

  def run(phase : String, sql : String) : Nil
    @file_system.phase = phase
    code = @database.exec(sql)
    raise "#{sql}: #{@database.error_message}" unless code == Grant::SQLite3::Engine::OK_CODE
  end

  def enter_wal_mode : Nil
    @file_system.phase = "enter wal"
    @engine_database.journal_mode = Grant::SQLiteEngine::JournalMode::Wal
  end

  def close : Nil
    @file_system.phase = "close"
    @database.close
  end

  # A table made and filled in rollback-journal mode, then in WAL mode two
  # commits, a TRUNCATE checkpoint, the commit that starts the WAL over,
  # and the close that checkpoints it; the syncs of all of it.
  def self.list_of_sync_lines(pragmas : String) : Array(String)
    connection = new
    connection.run("pragma", pragmas)
    connection.run("journal commit", "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)")
    connection.run("journal commit", "INSERT INTO notes(body) VALUES ('first')")
    connection.enter_wal_mode
    connection.run("wal commit", "INSERT INTO notes(body) VALUES ('second')")
    connection.run("wal commit", "INSERT INTO notes(body) VALUES ('third')")
    connection.run("checkpoint", "PRAGMA wal_checkpoint(TRUNCATE)")
    connection.run("wal commit", "INSERT INTO notes(body) VALUES ('fourth')")
    connection.close
    connection.file_system.list_of_sync_lines
  end
end

describe "Grant::SQLiteEngine PRAGMA fullfsync and checkpoint_fullfsync" do
  it "reads, sets and lists both flags as C does" do
    list_of_statements = [
      "PRAGMA fullfsync", "PRAGMA checkpoint_fullfsync", "SELECT * FROM pragma_fullfsync",
      "SELECT * FROM pragma_checkpoint_fullfsync", "PRAGMA fullfsync=ON", "PRAGMA fullfsync",
      "PRAGMA checkpoint_fullfsync", "PRAGMA checkpoint_fullfsync = 1", "PRAGMA checkpoint_fullfsync",
      "SELECT * FROM pragma_fullfsync", "SELECT * FROM pragma_checkpoint_fullfsync()", "PRAGMA fullfsync(off)",
      "PRAGMA fullfsync", "PRAGMA main.fullfsync=yes", "PRAGMA main.fullfsync", "PRAGMA FULLFSYNC=FALSE",
      "PRAGMA fullfsync", "PRAGMA fullfsync=256", "PRAGMA fullfsync", "PRAGMA fullfsync=2", "PRAGMA fullfsync",
      "PRAGMA fullfsync=full", "PRAGMA fullfsync", "PRAGMA nowhere.fullfsync", "PRAGMA nowhere.fullfsync=1",
      "BEGIN", "PRAGMA fullfsync=1", "PRAGMA fullfsync", "PRAGMA checkpoint_fullfsync=0", "COMMIT",
      "PRAGMA fullfsync", "PRAGMA checkpoint_fullfsync",
    ]
    DurabilityDifferential.differences(list_of_statements).should be_empty
  end

  it "reads each spelling of on and off as C does" do
    list_of_statements = [] of String
    DurabilityDifferential::VALUES.each do |value|
      list_of_statements << "PRAGMA fullfsync=0" << "PRAGMA fullfsync=#{value}" << "PRAGMA fullfsync"
      list_of_statements << "PRAGMA checkpoint_fullfsync=1" << "PRAGMA checkpoint_fullfsync(#{value})" << "PRAGMA checkpoint_fullfsync"
    end
    DurabilityDifferential.differences(list_of_statements).should be_empty
  end

  it "answers the statements of a durable connection as C does" do
    list_of_statements = [
      "PRAGMA busy_timeout=5000", "PRAGMA synchronous=FULL", "PRAGMA fullfsync=ON", "PRAGMA checkpoint_fullfsync=ON",
      "PRAGMA fullfsync", "PRAGMA checkpoint_fullfsync", "PRAGMA synchronous", "PRAGMA journal_mode=WAL",
      "CREATE TABLE ledger(writer TEXT, seq INTEGER)", "INSERT INTO ledger VALUES ('w1', 1)",
      "PRAGMA wal_checkpoint(TRUNCATE)", "PRAGMA fullfsync", "PRAGMA checkpoint_fullfsync", "PRAGMA synchronous",
      "SELECT * FROM ledger",
    ]
    DurabilityDifferential.differences(list_of_statements).should be_empty
  end

  it "matches C over 4,000 seeded random statements in 200 connections" do
    random = Random.new(20261124)
    list_of_differences = [] of String
    statement_count = 0
    200.times do
      list_of_statements = Array.new(20) { DurabilityDifferential.random_statement(random) }
      statement_count += list_of_statements.size
      list_of_differences.concat(DurabilityDifferential.differences(list_of_statements))
    end
    STDOUT.puts "\n  durability PRAGMA differential: #{statement_count} statements, seed 20261124, #{list_of_differences.size} differences"
    list_of_differences.first(5).should be_empty
    list_of_differences.size.should eq(0)
  end

  describe "the syncs that reach the file layer" do
    it "are all normal ones while both flags are off" do
      CountedConnection.list_of_sync_lines("PRAGMA synchronous=FULL").should eq([
        "journal commit journal normal", "journal commit journal normal", "journal commit database normal",
        "journal commit journal normal", "journal commit journal normal", "journal commit database normal",
        "enter wal journal normal", "enter wal journal normal", "enter wal database normal",
        "wal commit wal normal", "wal commit wal normal", "wal commit wal normal",
        "checkpoint wal normal", "checkpoint database normal",
        "wal commit wal normal", "wal commit wal normal",
        "close wal normal", "close database normal",
      ])
    end

    it "are all full ones with fullfsync on: database, journal, WAL and checkpoint" do
      lines = CountedConnection.list_of_sync_lines("PRAGMA synchronous=FULL; PRAGMA fullfsync=ON")
      lines.should eq(CountedConnection.list_of_sync_lines("PRAGMA synchronous=FULL").map(&.sub("normal", "full")))
      lines.count(&.ends_with?(" full")).should eq(18)
      %w[database journal wal].each { |kind| lines.count(&.includes?(" #{kind} ")).should be > 0 }
    end

    it "are all full ones for a durable connection (synchronous=FULL, fullfsync and checkpoint_fullfsync on)" do
      lines = CountedConnection.list_of_sync_lines("PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;")
      lines.size.should eq(18)
      lines.reject(&.ends_with?(" full")).should be_empty
    end

    # A checkpoint's syncs are the WAL and database syncs of the checkpoint
    # itself and the sync of the header of a WAL started (or started over),
    # which C makes with the checkpoint's flags (walFrames, syncHeader).
    it "are full ones only for a checkpoint with checkpoint_fullfsync alone" do
      CountedConnection.list_of_sync_lines("PRAGMA synchronous=FULL; PRAGMA checkpoint_fullfsync=ON").should eq([
        "journal commit journal normal", "journal commit journal normal", "journal commit database normal",
        "journal commit journal normal", "journal commit journal normal", "journal commit database normal",
        "enter wal journal normal", "enter wal journal normal", "enter wal database normal",
        "wal commit wal full", "wal commit wal normal", "wal commit wal normal",
        "checkpoint wal full", "checkpoint database full",
        "wal commit wal full", "wal commit wal normal",
        "close wal full", "close database full",
      ])
    end

    it "leave out the first journal sync and the WAL commit sync with synchronous=NORMAL" do
      CountedConnection.list_of_sync_lines("PRAGMA synchronous=NORMAL; PRAGMA fullfsync=ON").should eq([
        "journal commit journal full", "journal commit database full",
        "journal commit journal full", "journal commit database full",
        "enter wal journal full", "enter wal database full",
        "wal commit wal full",
        "checkpoint wal full", "checkpoint database full",
        "wal commit wal full",
        "close wal full", "close database full",
      ])
    end

    it "are none with synchronous=OFF, whatever the flags" do
      CountedConnection.list_of_sync_lines("PRAGMA synchronous=OFF; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON").should be_empty
    end

    it "go back to normal ones when fullfsync is turned off again" do
      connection = CountedConnection.new
      connection.run("on", "PRAGMA fullfsync=ON; CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)")
      connection.run("off", "PRAGMA fullfsync=OFF; INSERT INTO notes(body) VALUES ('first')")
      connection.close
      connection.file_system.list_of_sync_lines.should eq([
        "on journal full", "on journal full", "on database full",
        "off journal normal", "off journal normal", "off database normal",
      ])
    end

    it "keep the syncs of an open transaction as they were, as C does" do
      connection = CountedConnection.new
      connection.run("transaction", "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); BEGIN; " \
                                    "INSERT INTO notes(body) VALUES ('first'); PRAGMA fullfsync=ON; COMMIT")
      connection.run("after", "PRAGMA checkpoint_fullfsync=ON; INSERT INTO notes(body) VALUES ('second')")
      connection.close
      connection.file_system.list_of_sync_lines.should eq([
        "transaction journal normal", "transaction journal normal", "transaction database normal",
        "transaction journal normal", "transaction journal normal", "transaction database normal",
        "after journal full", "after journal full", "after database full",
      ])
    end

    it "rolls back a hot journal found at open with a full sync of the database" do
      file_system = SQLiteEngineCountingFileSystem.new
      database = Grant::SQLiteEngine::Database.open("counted.db", read_write: true, file_system: file_system)
      connection = Grant::SQLite3::Engine::GrantEngine::Database.new(database)
      connection.exec("CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes(body) VALUES ('first')")
      page = Bytes.new(4096)
      file_system.open("counted.db").read_at(0_i64, page)
      Grant::SQLiteEngine::RollbackJournal.write(file_system.open("counted.db-journal"), 4096, 2_u32, [{1_u32, page}], 7_u32)
      database.close
      file_system.list_of_sync_calls.clear
      file_system.phase = "reopen"
      Grant::SQLiteEngine::Database.open("counted.db", read_write: true, file_system: file_system).close
      file_system.list_of_sync_lines.should eq(["reopen database full"])
      file_system.exists?("counted.db-journal").should be_false
    end

    it "rolls back the unsynced journal of synchronous=OFF, whose size tells its record count" do
      file_system = SQLiteEngineCountingFileSystem.new
      database = Grant::SQLiteEngine::Database.open("counted.db", read_write: true, file_system: file_system)
      connection = Grant::SQLite3::Engine::GrantEngine::Database.new(database)
      connection.exec("CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes(body) VALUES ('first')")
      list_of_images = [1_u32, 2_u32].map do |page_number|
        page = Bytes.new(4096)
        file_system.open("counted.db").read_at((page_number.to_i64 - 1) * 4096, page)
        {page_number, page}
      end
      connection.exec("PRAGMA synchronous=OFF; INSERT INTO notes(body) VALUES ('second')")
      journal = file_system.open("counted.db-journal")
      Grant::SQLiteEngine::RollbackJournal.write(journal, 4096, 2_u32, list_of_images, 7_u32, Grant::SQLiteEngine::Synchronous::Off)
      header = Bytes.new(12)
      journal.read_at(0_i64, header)
      header[8, 4].should eq(Bytes[0xff, 0xff, 0xff, 0xff])
      database.close
      file_system.list_of_sync_calls.clear
      reopened = Grant::SQLite3::Engine::GrantEngine::Database.new(
        Grant::SQLiteEngine::Database.open("counted.db", read_write: true, file_system: file_system))
      DurabilityDifferential.outcome(reopened, "SELECT body FROM notes").should eq(%(code=101  ["body"] [["t:first"]]))
      reopened.close
    end
  end

  describe "Grant::SQLiteEngine::PosixFile#sync" do
    it "syncs a real file in both modes" do
      path = File.tempname("fullfsync", ".db")
      file = Grant::SQLiteEngine::PosixFileSystem.new.open(path)
      begin
        file.write_at(0_i64, "durable".to_slice)
        file.sync
        file.sync(Grant::SQLiteEngine::SyncMode::Normal)
        file.sync(Grant::SQLiteEngine::SyncMode::Full)
        File.read(path).should eq("durable")
      ensure
        file.close
        File.delete?(path)
      end
    end

    {% if flag?(:darwin) %}
      it "reaches fcntl(F_FULLFSYNC) on macOS, and the call succeeds on a real file" do
        Grant::SQLiteEngine::LibFileLock::F_FULLFSYNC.should eq(51)
        path = File.tempname("fullfsync", ".db")
        File.open(path, "w+b") do |file|
          file.sync = true
          file.write("durable".to_slice)
          Grant::SQLiteEngine::PosixFile.full_fsync?(file.fd).should be_true
        end
        File.delete?(path)
        # A descriptor that is not open is refused, which is what sends
        # `PosixFile#sync` on to fsync.
        Grant::SQLiteEngine::PosixFile.full_fsync?(-1).should be_false
      end

      it "runs a durable connection on real files with every pragma read back as set" do
        directory = File.tempname("fullfsync-real")
        Dir.mkdir_p(directory)
        begin
          code, database = Grant::SQLite3::Engine::GrantEngine.new.open(File.join(directory, "real.db"))
          code.should eq(Grant::SQLite3::Engine::OK_CODE)
          database.exec("PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;").should eq(0)
          database.exec("CREATE TABLE ledger(writer TEXT, seq INTEGER); INSERT INTO ledger VALUES ('w1', 1); PRAGMA journal_mode=WAL; " \
                        "INSERT INTO ledger VALUES ('w1', 2); PRAGMA wal_checkpoint(TRUNCATE); INSERT INTO ledger VALUES ('w1', 3)").should eq(0)
          DurabilityDifferential.outcome(database, "PRAGMA fullfsync").should eq(%(code=101  ["fullfsync"] [["i:1"]]))
          DurabilityDifferential.outcome(database, "PRAGMA checkpoint_fullfsync").should eq(%(code=101  ["checkpoint_fullfsync"] [["i:1"]]))
          DurabilityDifferential.outcome(database, "PRAGMA synchronous").should eq(%(code=101  ["synchronous"] [["i:2"]]))
          DurabilityDifferential.outcome(database, "SELECT count(*) FROM ledger").should eq(%(code=101  ["count(*)"] [["i:3"]]))
          database.close
        ensure
          FileUtils.rm_rf(directory)
        end
      end
    {% end %}
  end
end
