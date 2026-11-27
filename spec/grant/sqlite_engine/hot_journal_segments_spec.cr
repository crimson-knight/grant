require "spec"
require "../../support/sqlite_engine/hot_journal_differential"

# A hot rollback journal of several segments, the kind C SQLite leaves when
# it dies in a transaction after spilling dirty pages to the database file
# (each spill first syncs the journal and starts a new segment): Grant's
# engine rolls it back to the same database bytes as C does, walking every
# segment as pager_playback and readJournalHdr do.
#
# The journals come from C itself (a helper process killed before COMMIT,
# after it has spilled), and from C's journals laid out again byte for
# byte with one rule of the format changed: an empty segment in the
# middle, a last segment whose count the file size tells, 4,096-byte
# sectors, a page journaled twice, a damaged record or header.
module HotJournalSegments
  alias Journal = SQLiteEngineHotJournal
  alias Differential = SQLiteEngineHotJournalDifferential

  class_getter scratch : String { File.tempname("grant_hot_journal_segments").tap { |path| Dir.mkdir_p(path) } }

  # The engine's and C's rollback of *database* and *journal*, checked to
  # agree byte for byte; returns the engine's.
  def self.both_roll_back(database : Bytes, journal : Bytes) : Differential::Rollback
    c_rollback = Differential.roll_back(:libsqlite3, database, journal, scratch)
    engine = Differential.roll_back(:grant, database, journal, scratch)
    # Each engine words integrity_check's complaints its own way; both
    # must find a damaged database damaged.
    (engine.integrity == "ok").should eq(c_rollback.integrity == "ok")
    engine.journal_left.should eq(c_rollback.journal_left)
    engine.database.size.should eq(c_rollback.database.size)
    first_difference = (0...engine.database.size).find { |index| engine.database[index] != c_rollback.database[index] }
    first_difference.should be_nil
    engine
  end

  # The synced segments of *crash*'s journal (the ones C rolls back from),
  # copied so a spec can change them.
  def self.synced_segments(crash : Differential::Crash) : Array(Journal::Segment)
    list = crash.list_of_segments.select(&.synced?).map(&.copy)
    list.size.should be >= 2
    list
  end

  class_getter crash : Differential::Crash { Differential.write_with_c(scratch, spills: 3) }
end

describe "Grant::SQLiteEngine hot journal of several segments" do
  after_all do
    SQLiteEngineHotJournalDifferential.remove_writer
    FileUtils.rm_rf(HotJournalSegments.scratch)
  end

  {"FULL", "NORMAL"}.each do |synchronous|
    it "rolls back the journal C leaves when it dies after spilling (synchronous=#{synchronous}) as C does" do
      crash = SQLiteEngineHotJournalDifferential.write_with_c(HotJournalSegments.scratch, spills: 3, synchronous: synchronous)
      list_of_segments = crash.list_of_segments
      list_of_segments.count(&.synced?).should be >= 3
      list_of_segments.map(&.offset).each { |offset| (offset % list_of_segments.first.sector_size).should eq(0) }
      crash.database.should_not eq(crash.before_transaction)
      rollback = HotJournalSegments.both_roll_back(crash.database, crash.journal)
      rollback.integrity.should eq("ok")
      rollback.journal_left.should be_false
      rollback.database.should eq(crash.before_transaction)
    end
  end

  it "reads on past a segment that holds no records" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    empty = SQLiteEngineHotJournal::Segment.new(0_u32, 77_u32, list.first.initial_page_count, list.first.sector_size, list.first.page_size)
    list.insert(1, empty)
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.database.should eq(crash.before_transaction)
  end

  # The segment C was filling when it died: its records are written but
  # its count is still 0, and none of its pages reached the database.
  it "plays back none of a last segment whose nRec is still 0" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    unsynced = SQLiteEngineHotJournal::Segment.new(0_u32, 91_u32, list.first.initial_page_count, list.first.sector_size, list.first.page_size)
    image = Bytes.new(unsynced.page_size.to_i, 0x77_u8)
    {2_u32, 3_u32}.each { |page_number| unsynced.list_of_records << SQLiteEngineHotJournal::PageRecord.checked(unsynced.nonce, page_number, image) }
    list << unsynced
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.database.should eq(crash.before_transaction)
  end

  it "takes a last segment's record count from the file size when its nRec is 0xffffffff" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    list.last.record_count = SQLiteEngineHotJournal::RECORD_COUNT_FROM_SIZE
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.database.should eq(crash.before_transaction)
  end

  it "places every header by the first header's sector size and takes the page count from the first header only" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    list.first.sector_size = 4096_u32
    list[1..].each do |segment|
      segment.sector_size = 64_u32
      segment.page_size = 0_u32
      segment.initial_page_count = 1_u32
    end
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.database.should eq(crash.before_transaction)
  end

  # C writes every record it reads (no pDone set on a main-journal
  # playback), so of two images of one page the later one stays. The
  # later image here is page 1 with user_version 7, which changes nothing
  # integrity_check reads.
  it "writes a page journaled again in a later segment as C does, keeping the later image" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    holder = list.index!(&.list_of_records.any? { |page_record| page_record.page_number == 1 })
    holder.should be < list.size - 1
    expected = crash.before_transaction.dup
    SQLiteEngineHotJournal.put_u32(expected, 60, 7_u32)
    last = list.last
    last.list_of_records << SQLiteEngineHotJournal::PageRecord.checked(last.nonce, 1_u32, expected[0, last.page_size.to_i].dup)
    last.record_count += 1
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.integrity.should eq("ok")
    rollback.database.should eq(expected)
  end

  it "skips a record past the original page count before checking its checksum" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    second = list[1]
    image = Bytes.new(second.page_size.to_i, 0x11_u8)
    beyond = SQLiteEngineHotJournal::PageRecord.new(list.first.initial_page_count + 5, image, 0xdead_beef_u32)
    second.list_of_records.unshift(beyond)
    second.record_count += 1
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.database.should eq(crash.before_transaction)
  end

  it "stops the whole playback at a record whose checksum fails in a later segment" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    second = list[1]
    damaged = second.list_of_records[0]
    second.list_of_records[0] = SQLiteEngineHotJournal::PageRecord.new(damaged.page_number, damaged.image, damaged.checksum &+ 1)
    rollback = HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
    rollback.database.should_not eq(crash.before_transaction)
  end

  it "stops at a later header without the magic" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    list[1].magic = Bytes.new(8, 0_u8)
    HotJournalSegments.both_roll_back(crash.database, SQLiteEngineHotJournal.encode(list))
  end

  it "stops at a segment cut short in the middle of a record" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    journal = SQLiteEngineHotJournal.encode(list)
    cut = list.last
    HotJournalSegments.both_roll_back(crash.database, journal[0, journal.size - cut.page_size.to_i // 2])
  end

  it "leaves the database as it is when the first header's sector size is out of range" do
    crash = HotJournalSegments.crash
    list = HotJournalSegments.synced_segments(crash)
    journal = SQLiteEngineHotJournal.encode(list)
    SQLiteEngineHotJournal.put_u32(journal, 20, 3000_u32)
    rollback = HotJournalSegments.both_roll_back(crash.database, journal)
    rollback.database.should eq(crash.database)
  end
end
