# A helper process of spec/support/sqlite_engine/hot_journal_differential.cr:
# C SQLite leaves a hot rollback journal of several segments. It makes a
# database of ROWS rows, copies it to PATH.pre (the state before the
# transaction), then opens a transaction that updates and inserts rows one
# at a time with a ten-page cache and a ten-page spill threshold (some
# builds, such as the one macOS ships, set cache_spill far past
# cache_size), so C spills dirty pages to the database file again and
# again, each time after syncing a journal segment. Once the journal holds
# SPILLS synced segments the process ends at once with _exit, before the
# commit, leaving the journal hot.
#
#   hot_journal_writer PATH SPILLS ROWS SYNCHRONOUS PAGE_SIZE
#
# SYNCHRONOUS: FULL or NORMAL. Prints "segments <n>" just before it exits.
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"
require "./hot_journal"

module HotJournalWriter
  alias Engine = Grant::SQLite3::Engine

  # More statements than any spill count asks for: the helper gives up
  # here rather than loop forever when C never spills.
  STATEMENT_LIMIT = 5_000

  def self.run(database : Engine::Database, sql : String) : Nil
    code = database.exec(sql)
    abort "#{sql}: #{code} #{database.error_message}" unless code == Engine::OK_CODE
  end

  def self.perform(path : String, spills : Int32, rows : Int32, synchronous : String, page_size : Int32) : NoReturn
    engine = Engine::LibSQLite3Engine.new
    code, database = engine.open(path)
    abort "open #{code} #{database.error_message}" unless code == Engine::OK_CODE
    run(database, "PRAGMA page_size=#{page_size}; PRAGMA journal_mode=DELETE; " \
                  "CREATE TABLE entries (id INTEGER PRIMARY KEY, payload TEXT); CREATE INDEX entries_payload ON entries (payload); " \
                  "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < #{rows}) " \
                  "INSERT INTO entries SELECT i, printf('%0300d', i) FROM n")
    database.close
    File.copy(path, "#{path}.pre")

    code, database = engine.open(path)
    abort "reopen #{code} #{database.error_message}" unless code == Engine::OK_CODE
    run(database, "PRAGMA cache_size=10; PRAGMA cache_spill=10; PRAGMA synchronous=#{synchronous}; BEGIN")
    journal_path = "#{path}-journal"
    STATEMENT_LIMIT.times do |number|
      id = number % rows + 1
      run(database, "UPDATE entries SET payload = printf('%0300d', -#{number}) WHERE id = #{id}; " \
                    "INSERT INTO entries (payload) VALUES (printf('%0400d', #{number}))")
      segments = SQLiteEngineHotJournal.synced_segment_count(journal_path)
      if segments >= spills
        STDOUT.puts "segments #{segments}"
        STDOUT.flush
        LibC._exit(0)
      end
    end
    abort "no #{spills} spills after #{STATEMENT_LIMIT} statements"
  end
end

HotJournalWriter.perform(ARGV[0], ARGV[1].to_i, ARGV[2].to_i, ARGV[3], ARGV[4].to_i)
