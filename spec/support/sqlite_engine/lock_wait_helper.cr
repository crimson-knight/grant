# A helper process of spec/grant/sqlite_engine/lock_wait_processes_spec.cr:
# one connection, through Grant's engine or C SQLite, doing one job on a
# database other processes use at the same time. It prints what happened
# and exits 0 when every statement succeeded.
#
#   lock_wait_helper ROLE ENGINE PATH
#
# ROLE: writer_to_kill (inserts until killed), reader (counts the rows),
# inserter (INSERTS_EACH single-row transactions), wal_switcher (turns the
# database to WAL, then inserts one row). ENGINE: grant or libsqlite3.
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"

module LockWaitHelper
  alias Engine = Grant::SQLite3::Engine

  INSERTS_EACH = 40

  def self.leave(message : String, status : Int32 = 1) : NoReturn
    STDOUT.puts message
    STDOUT.flush
    exit status
  end

  def self.perform(role : String, engine_name : String, path : String) : NoReturn
    engine = engine_name == "grant" ? Engine::GrantEngine.new : Engine::LibSQLite3Engine.new
    code, database = engine.open(path)
    leave("open #{code} #{database.error_message}") unless code == Engine::OK_CODE
    code = database.exec("PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;")
    leave("pragmas #{code} #{database.error_message}") unless code == Engine::OK_CODE
    case role
    when "wal_switcher"
      code = database.exec("PRAGMA journal_mode=WAL; INSERT INTO entries (label) VALUES ('#{Process.pid}')")
      leave("switch: #{code} #{database.error_message}") unless code == Engine::OK_CODE
      leave("rows 1", 0)
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
end

LockWaitHelper.perform(ARGV[0], ARGV[1], ARGV[2])
