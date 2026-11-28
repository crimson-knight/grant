require "file_utils"
require "../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../src/grant/drivers/sqlite3/grant_engine"
require "../../../src/grant/drivers/sqlite3/libsqlite3"
require "../crystal_compiler"
require "./hot_journal"

# Hot rollback journals C SQLite leaves, and what each engine makes of
# them. For the specs of hot-journal playback:
#
#   crash = SQLiteEngineHotJournalDifferential.write_with_c(directory, spills: 3)
#   crash.list_of_segments              # the journal's segments, as C walks them
#   engine = SQLiteEngineHotJournalDifferential.roll_back(:grant, crash.database, crash.journal, scratch)
#   c = SQLiteEngineHotJournalDifferential.roll_back(:libsqlite3, crash.database, crash.journal, scratch)
#   engine.database.should eq(c.database)
#   engine.database.should eq(crash.before_transaction)
#
# `write_with_c` runs spec/support/sqlite_engine/hot_journal_writer.cr in a
# process of its own, built once (SPEC_GROUP_LINK_FLAGS links it to the
# same libsqlite3 as the specs). `roll_back` takes any database and journal
# bytes, so a spec can also hand it a journal laid out with
# `SQLiteEngineHotJournal.encode`.
module SQLiteEngineHotJournalDifferential
  alias Engine = Grant::SQLite3::Engine

  WRITER_SOURCE = Path[__DIR__] / "hot_journal_writer.cr"

  class_property writer_path = ""

  # What C left after it was killed mid-transaction: the database file, its
  # hot journal, and the database as it was before the transaction began.
  record Crash, database : Bytes, journal : Bytes, before_transaction : Bytes do
    def list_of_segments : Array(SQLiteEngineHotJournal::Segment)
      SQLiteEngineHotJournal.list_of_segments(journal)
    end
  end

  # One engine's rollback: the database file's bytes afterward, the
  # answer of PRAGMA integrity_check, and whether the journal is gone.
  record Rollback, database : Bytes, integrity : String, journal_left : Bool

  def self.build_writer : String
    return writer_path unless writer_path.empty?
    binary_path = File.tempname("grant_hot_journal_writer")
    arguments = ["build", "--no-color", "-o", binary_path, WRITER_SOURCE.normalize.to_s]
    if link_flags = ENV["SPEC_GROUP_LINK_FLAGS"]?
      arguments << "--link-flags" << link_flags unless link_flags.empty?
    end
    output = IO::Memory.new
    status = Process.run(spec_crystal_compiler, arguments, output: output, error: output, chdir: File.expand_path("../../..", __DIR__))
    raise "building the hot journal writer failed:\n#{output}" unless status.success?
    self.writer_path = binary_path
  end

  def self.remove_writer : Nil
    return if writer_path.empty?
    File.delete?(writer_path)
    File.delete?("#{writer_path}.dwarf")
    self.writer_path = ""
  end

  # C SQLite builds a database of *rows* rows in *directory* and is killed
  # (it ends with _exit, before COMMIT) once its open transaction has
  # synced *spills* journal segments, each one ahead of a spill of dirty
  # pages to the database file.
  def self.write_with_c(directory : String | Path, spills : Int32, rows : Int32 = 2000,
                        synchronous : String = "FULL", page_size : Int32 = 1024) : Crash
    path = Path[directory] / "c_writer.db"
    {"", "-journal", ".pre"}.each { |suffix| File.delete?("#{path}#{suffix}") }
    output = IO::Memory.new
    status = Process.run(build_writer, [path.to_s, spills.to_s, rows.to_s, synchronous, page_size.to_s], output: output, error: output)
    raise "the hot journal writer failed (#{status.exit_code}): #{output}" unless status.success?
    Crash.new(read("#{path}"), read("#{path}-journal"), read("#{path}.pre"))
  end

  # Writes *database* and *journal* (as DATABASE-journal) to a fresh
  # directory under *scratch*, opens the database with *engine* (:grant or
  # :libsqlite3), which rolls the hot journal back, runs PRAGMA
  # integrity_check, and closes it.
  def self.roll_back(engine : Symbol, database : Bytes, journal : Bytes, scratch : String | Path) : Rollback
    directory = Path[scratch] / "#{engine}-#{Random.new.hex(4)}"
    Dir.mkdir_p(directory)
    path = (directory / "rolled_back.db").to_s
    File.write(path, database)
    File.write("#{path}-journal", journal)
    code, connection = Engine.named(engine).open(path)
    raise "#{engine} open: #{code} #{connection.error_message}" unless code == Engine::OK_CODE
    integrity = integrity_check(connection)
    connection.close
    rollback = Rollback.new(read(path), integrity, File.exists?("#{path}-journal"))
    FileUtils.rm_rf(directory)
    rollback
  end

  private def self.integrity_check(connection : Engine::Database) : String
    code, statement = connection.prepare("PRAGMA integrity_check")
    return "prepare #{code}: #{connection.error_message}" unless code == Engine::OK_CODE
    list_of_lines = [] of String
    while (step = statement.step) == Engine::ROW_CODE
      list_of_lines << statement.column_text(0)
    end
    list_of_lines << "step #{step}: #{connection.error_message}" unless step == Engine::DONE_CODE
    statement.finalize_statement
    list_of_lines.join('\n')
  end

  private def self.read(path : String) : Bytes
    File.open(path, "rb", &.getb_to_end)
  end
end
