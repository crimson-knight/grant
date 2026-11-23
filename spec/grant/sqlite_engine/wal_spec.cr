require "spec"
require "file_utils"
require "../../support/sqlite_engine/crash_file"
require "../../support/sqlite_engine/sqlite3_shell"

private alias Engine = Grant::SQLiteEngine

private def values(*list) : Array(Engine::Value)
  list.to_a.map(&.as(Engine::Value))
end

# A fresh database path in a directory of this spec run.
private def wal_database(name : String) : String
  directory = Path[Dir.tempdir] / "grant-sqlite-engine-wal-#{Process.pid}"
  Dir.mkdir_p(directory)
  path = (directory / "#{name}.db").to_s
  %w[-wal -shm -journal].each { |suffix| File.delete?("#{path}#{suffix}") }
  File.delete?(path)
  path
end

private def sqlite3(path : String, sql : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("sqlite3", [path, sql], output: output, error: error)
  raise "sqlite3 failed: #{error}" unless status.success? && error.empty?
  output.to_s
end

private def open_wal(path : String, wal_autocheckpoint : Int32 = 1000) : Engine::Database
  Engine::Database.open(path, read_write: true, journal_mode: Engine::JournalMode::Wal, wal_autocheckpoint: wal_autocheckpoint)
end

private def header_bytes(path : String) : Bytes
  bytes = Bytes.new(100)
  File.open(path, "rb", &.read_fully(bytes))
  bytes
end

private def engine_rows(database : Engine::Database, table : String) : Array(Array(Engine::Value))
  database.rows(table).map(&.values)
end

describe "Grant::SQLiteEngine WAL mode" do
  describe "#journal_mode=" do
    it "writes 2 into header bytes 18 and 19, as C does, and back to 1 when the WAL is left" do
      path = wal_database("switch")
      database = open_wal(path)
      database.journal_mode.should eq(Engine::JournalMode::Wal)
      header_bytes(path)[18, 2].should eq(Bytes[2, 2])
      sqlite3(path, "PRAGMA journal_mode;").should eq("wal\n")
      database.journal_mode = Engine::JournalMode::Delete
      header_bytes(path)[18, 2].should eq(Bytes[1, 1])
      File.exists?("#{path}-wal").should be_false
      File.exists?("#{path}-shm").should be_false
      database.close
      sqlite3(path, "PRAGMA journal_mode;").should eq("delete\n")
    end

    it "opens a database C put in WAL mode in WAL mode" do
      path = wal_database("c_wal")
      sqlite3(path, "PRAGMA journal_mode=WAL; CREATE TABLE t(a); INSERT INTO t VALUES (1);")
      database = Engine::Database.open(path, read_write: true)
      database.journal_mode.should eq(Engine::JournalMode::Wal)
      engine_rows(database, "t").should eq([values(1_i64)])
      database.close
    end
  end

  describe "the -wal and -shm files" do
    it "commits frames C reads while the engine still has the database open" do
      path = wal_database("frames")
      database = open_wal(path, wal_autocheckpoint: 0)
      database.create_table("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT)")
      database.transaction do |writer|
        200.times { |number| writer.insert("t", nil, values(nil, "row #{number}" * 20)) }
      end
      File.size("#{path}-wal").should be > 32
      File.size(path).should eq(4096)
      sqlite3(path, "PRAGMA integrity_check; SELECT count(*), sum(a) FROM t;").should eq("ok\n200|20100\n")
      database.close
      File.exists?("#{path}-wal").should be_false
      sqlite3(path, "SELECT count(*) FROM t;").should eq("200\n")
    end

    it "reads what C commits to the WAL while the engine holds the database open" do
      path = wal_database("c_frames")
      database = open_wal(path)
      database.create_table("CREATE TABLE t(a)")
      sqlite3(path, "INSERT INTO t VALUES (1), (2); INSERT INTO t VALUES (3);")
      # The engine's SHARED lock kept C from checkpointing and deleting the WAL.
      File.size("#{path}-wal").should be > 32
      engine_rows(database, "t").should eq([values(1_i64), values(2_i64), values(3_i64)])
      database.insert("t", nil, values(4_i64))
      sqlite3(path, "SELECT group_concat(a) FROM t;").should eq("1,2,3,4\n")
      database.close
    end

    it "keeps a reader on one snapshot while another connection commits" do
      path = wal_database("snapshot")
      writer = open_wal(path)
      writer.create_table("CREATE TABLE t(a)")
      writer.insert("t", nil, values(1_i64))
      reader = Engine::Database.open(path, read_write: true)
      reader.pager.with_read_lock do
        reader.rows("t").size.should eq(1)
        writer.insert("t", nil, values(2_i64))
        sqlite3(path, "INSERT INTO t VALUES (3);")
        reader.rows("t").size.should eq(1)
      end
      reader.rows("t").size.should eq(3)
      reader.close
      writer.close
    end
  end

  describe "#checkpoint" do
    it "reports busy, log and checkpointed frames as C's PRAGMA wal_checkpoint does" do
      engine_path = wal_database("ckpt_engine")
      c_path = wal_database("ckpt_c")
      database = open_wal(engine_path, wal_autocheckpoint: 0)
      database.create_table("CREATE TABLE t(a)")
      5.times { |number| database.insert("t", nil, values(number.to_i64)) }
      passive = database.checkpoint
      truncate = database.checkpoint(Engine::CheckpointMode::Truncate)
      database.close
      c_result = sqlite3(c_path, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(a); " \
                                 "INSERT INTO t VALUES (0); INSERT INTO t VALUES (1); INSERT INTO t VALUES (2); " \
                                 "INSERT INTO t VALUES (3); INSERT INTO t VALUES (4); PRAGMA wal_checkpoint; PRAGMA wal_checkpoint(TRUNCATE);")
      c_result.should eq("wal\n0\n0|#{passive.log_frames}|#{passive.checkpointed_frames}\n" \
                         "#{truncate.busy ? 1 : 0}|#{truncate.log_frames}|#{truncate.checkpointed_frames}\n")
      truncate.log_frames.should eq(0)
    end

    it "copies no frame a C reader still needs and finishes once it leaves" do
      path = wal_database("ckpt_reader")
      database = open_wal(path, wal_autocheckpoint: 0)
      database.create_table("CREATE TABLE t(a)")
      database.insert("t", nil, values(1_i64))
      shell = SQLiteEngineShell.new(path)
      shell.run("BEGIN; SELECT count(*) FROM t;").should eq(["1"])
      database.insert("t", nil, values(2_i64))
      result = database.checkpoint(Engine::CheckpointMode::Restart)
      result.busy.should be_true
      result.checkpointed_frames.should be < result.log_frames
      shell.run("SELECT count(*) FROM t; COMMIT;").should eq(["1"])
      result = database.checkpoint(Engine::CheckpointMode::Restart)
      result.busy.should be_false
      result.checkpointed_frames.should eq(result.log_frames)
      shell.close
      database.close
    end
  end

  describe "locks shared with C" do
    it "refuses a write while C holds the WAL write lock, and writes once C commits" do
      path = wal_database("write_lock")
      database = open_wal(path)
      database.create_table("CREATE TABLE t(a)")
      shell = SQLiteEngineShell.new(path)
      shell.run("BEGIN IMMEDIATE; INSERT INTO t VALUES (1);").should be_empty
      expect_raises(Engine::Busy) { database.insert("t", nil, values(2_i64)) }
      shell.run("COMMIT;").should be_empty
      database.insert("t", nil, values(2_i64))
      engine_rows(database, "t").should eq([values(1_i64), values(2_i64)])
      shell.close
      database.close
    end

    it "makes C wait for the engine's write transaction, as two C connections would" do
      path = wal_database("engine_writes")
      database = open_wal(path)
      database.create_table("CREATE TABLE t(a)")
      shell = SQLiteEngineShell.new(path)
      database.pager.begin_write
      SQLiteEngineShell.busy?(shell.run("INSERT INTO t VALUES (1);")).should be_true
      shell.run("SELECT count(*) FROM t;").should eq(["0"])
      database.pager.rollback
      shell.run("INSERT INTO t VALUES (1);").should be_empty
      shell.close
      database.close
    end

    it "answers a stale snapshot's write with busy, as C's SQLITE_BUSY_SNAPSHOT" do
      path = wal_database("stale")
      database = open_wal(path)
      database.create_table("CREATE TABLE t(a)")
      database.pager.acquire_read_lock
      database.rows("t")
      sqlite3(path, "INSERT INTO t VALUES (1);")
      expect_raises(Engine::BusySnapshot) { database.pager.begin_write(refresh_snapshot: false) }
      database.pager.release_read_lock
      database.insert("t", nil, values(2_i64))
      database.close
    end

    it "refuses to leave WAL mode while C has the database open" do
      path = wal_database("leave_busy")
      database = open_wal(path)
      database.create_table("CREATE TABLE t(a)")
      shell = SQLiteEngineShell.new(path)
      shell.run("SELECT count(*) FROM t;").should eq(["0"])
      expect_raises(Engine::Busy) { database.journal_mode = Engine::JournalMode::Delete }
      database.journal_mode.should eq(Engine::JournalMode::Wal)
      shell.close
      database.journal_mode = Engine::JournalMode::Delete
      database.close
    end
  end

  describe "recovery" do
    it "rebuilds the wal-index from the WAL after a crash, keeping committed frames only" do
      path = wal_database("recover")
      database = open_wal(path, wal_autocheckpoint: 0)
      database.create_table("CREATE TABLE t(a)")
      3.times { |number| database.insert("t", nil, values(number.to_i64)) }
      copy = wal_database("recover_copy")
      File.copy(path, copy)
      File.copy("#{path}-wal", "#{copy}-wal")
      # A torn last frame: the copy loses the end of the WAL.
      File.open("#{copy}-wal", "r+b") { |file| file.truncate(file.size - 100) }
      database.close
      reopened = Engine::Database.open(copy, read_write: true)
      engine_rows(reopened, "t").should eq([values(0_i64), values(1_i64)])
      reopened.close
      sqlite3(copy, "PRAGMA integrity_check; SELECT group_concat(a) FROM t;").should eq("ok\n0,1\n")
    end
  end

  describe "two connections of one process" do
    it "lets one write while the other reads, and both see the commit afterward" do
      path = wal_database("two")
      first = open_wal(path)
      first.create_table("CREATE TABLE t(a)")
      second = Engine::Database.open(path, read_write: true)
      second.insert("t", nil, values(1_i64))
      first.insert("t", nil, values(2_i64))
      engine_rows(first, "t").should eq(engine_rows(second, "t"))
      second.close
      # The first connection still holds its locks after the second closes.
      File.exists?("#{path}-wal").should be_true
      shell = SQLiteEngineShell.new(path)
      SQLiteEngineShell.busy?(shell.run("PRAGMA journal_mode=DELETE;")).should be_true
      shell.close
      first.close
      sqlite3(path, "SELECT count(*) FROM t;").should eq("2\n")
    end
  end
end
