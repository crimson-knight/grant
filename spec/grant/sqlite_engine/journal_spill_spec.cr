require "spec"
require "../../support/sqlite_engine/hot_journal_differential"
require "../../support/sqlite_engine/reference_library"
require "../../support/sqlite_engine/counting_file_system"

# The rollback journal written while the transaction runs, with C's cache
# spills (pagerStress): once the changed pages reach C's cache limit, the
# journal's segment is synced, the next segment starts, and the changed
# pages go to the database file before COMMIT. Each case runs the same
# statements on Grant's engine and on C SQLite in this process and
# compares what each leaves: the journal's segments, the hot journal a
# crash would leave (which the other engine must roll back), and the rows
# after a rollback of the transaction, a statement or a savepoint.
#
# PRAGMA cache_spill=1 is C's own default (szSpill); it is sent for C
# builds, such as the one macOS ships, that set it far past cache_size.
module JournalSpill
  alias Engine = Grant::SQLite3::Engine
  alias Differential = SQLiteEngineHotJournalDifferential

  class_getter scratch : String { File.tempname("grant_journal_spill").tap { |path| Dir.mkdir_p(path) } }

  # One row a page (3,000-byte blobs on 4,096-byte pages), *rows* rows.
  PAGE_ROWS = "CREATE TABLE pages (id INTEGER PRIMARY KEY, body BLOB); " \
              "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < %d) " \
              "INSERT INTO pages SELECT i, zeroblob(3000) FROM n"
  # Small indexed rows, much as the hot journal writer of
  # spec/support/sqlite_engine/hot_journal_writer.cr makes them.
  INDEXED_ROWS = "CREATE TABLE entries (id INTEGER PRIMARY KEY, payload TEXT UNIQUE); " \
                 "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < %d) " \
                 "INSERT INTO entries SELECT i, hex(zeroblob(150)) || i FROM n"

  def self.run(database : Engine::Database, sql : String) : Nil
    code = database.exec(sql)
    raise "#{sql[0, 120]}: #{code} #{database.error_message}" unless code == Engine::OK_CODE
  end

  def self.open(engine : Symbol, path : String) : Engine::Database
    code, database = Engine.named(engine).open(path)
    raise "#{engine} open #{code}: #{database.error_message}" unless code == Engine::OK_CODE
    database
  end

  # A fresh database at *name* in the scratch folder, built by C with
  # *setup*; returns its path.
  def self.fresh_database(name : String, setup : String) : String
    path = File.join(scratch, name)
    {path, "#{path}-journal"}.each { |file| File.delete?(file) }
    creator = open(:libsqlite3, path)
    run(creator, setup)
    creator.close
    path
  end

  # True when the linked C library is SQLite 3.51.0 with upstream's page
  # cache sizing (cache_size -2000 by default): the build whose spill
  # points the engine follows page for page. The build macOS ships sizes
  # its cache otherwise.
  class_getter? upstream_page_cache : Bool { SQLiteEngineReferenceLibrary.linked? && default_cache_size == "-2000" }

  def self.default_cache_size : String
    answer(:libsqlite3, "PRAGMA cache_size")
  end

  # The first column of *sql*'s first row on a new in-memory connection.
  def self.answer(engine : Symbol, sql : String) : String
    database = open(engine, ":memory:")
    code, statement = database.prepare(sql)
    text = code == Engine::OK_CODE && statement.step == Engine::ROW_CODE ? statement.column_text(0) : ""
    statement.finalize_statement
    database.close
    text
  end

  # True when the engine's page cache defaults (cache_size and the
  # cache_spill it reads) are the linked C library's: the C library is
  # the build this platform ships, whose defaults the engine takes.
  def self.same_cache_defaults? : Bool
    {"PRAGMA cache_size", "PRAGMA cache_spill"}.all? { |sql| answer(:grant, sql) == answer(:libsqlite3, sql) }
  end

  # The sector size field (header bytes 20 to 23) of the hot journal
  # *engine* leaves once its transaction has synced a journal segment.
  def self.journal_sector_size(engine : Symbol) : UInt32
    journal = crash_after_spills(engine, 1, "FULL").journal
    IO::ByteFormat::BigEndian.decode(UInt32, journal[20, 4])
  end

  def self.read(path : String) : Bytes
    File.open(path, "rb", &.getb_to_end)
  end

  # The statements of a long transaction: updates by rowid in a scrambled
  # order over *rows* one-page rows (new bytes: C writes no page whose
  # row is rewritten unchanged), then appended rows and deletes.
  def self.page_statements(rows : Int32) : Array(String)
    list = (0...rows).map { |index| "UPDATE pages SET body = randomblob(3000) WHERE id = #{(index * 7919) % rows + 1}" }
    (1..40).each { |number| list << "INSERT INTO pages (body) VALUES (zeroblob(3000))"; list << "DELETE FROM pages WHERE id = #{number * 13}" }
    list
  end

  # The hot journal writer's statements: an update and an insert each.
  def self.indexed_statements(count : Int32, rows : Int32) : Array(String)
    (0...count).map do |number|
      "UPDATE entries SET payload = hex(zeroblob(150)) || '-#{number}' WHERE id = #{number % rows + 1}; " \
      "INSERT INTO entries (payload) VALUES (hex(zeroblob(200)) || '#{number}')"
    end
  end

  # Runs *statements* in one transaction on *engine* and returns the
  # record count of each synced journal segment just before COMMIT.
  # *pragmas* set the page cache first (by default cache_size and
  # upstream's cache_spill of 1).
  def self.segment_layout(engine : Symbol, setup : String, statements : Array(String), cache_size : Int32,
                          pragmas : String = "PRAGMA cache_size=#{cache_size}; PRAGMA cache_spill=1;") : Array(UInt32)
    path = fresh_database("layout_#{engine}.db", setup)
    database = open(engine, path)
    run(database, "#{pragmas} BEGIN")
    statements.each { |sql| run(database, sql) }
    layout = SQLiteEngineHotJournal.list_of_segments(read("#{path}-journal")).select(&.synced?).map(&.record_count)
    run(database, "COMMIT")
    database.close
    layout
  end

  # What a crash leaves once *engine*'s open transaction has synced
  # *spills* journal segments: the database and journal bytes as they are
  # on disk at that moment (the process is still running; nothing more is
  # written before the copy), and the database before the transaction.
  def self.crash_after_spills(engine : Symbol, spills : Int32, synchronous : String) : Differential::Crash
    path = fresh_database("crash_#{engine}.db", INDEXED_ROWS % 2000)
    before = read(path)
    database = open(engine, path)
    run(database, "PRAGMA cache_size=10; PRAGMA cache_spill=1; PRAGMA synchronous=#{synchronous}; BEGIN")
    journal_path = "#{path}-journal"
    indexed_statements(4000, 2000).each do |sql|
      run(database, sql)
      journal = read(journal_path)
      synced = SQLiteEngineHotJournal.list_of_segments(journal).count(&.synced?)
      written = read(path)
      # synchronous=OFF keeps one segment, whose count the size tells.
      if (synchronous == "OFF" || synced >= spills) && written != before
        run(database, "ROLLBACK")
        database.close
        return Differential::Crash.new(written, journal, before)
      end
    end
    raise "#{engine} synced no #{spills} journal segments"
  end

  # Runs *script* (statements, each with the result code it must give) on
  # *engine* against a fresh database and returns the rows and
  # integrity_check afterward. (The page and freelist counts are left out:
  # after this script they differ from C's with no spill at all.)
  def self.rows_after(engine : Symbol, script : Array({String, Int32})) : String
    path = fresh_database("rows_#{engine}.db", INDEXED_ROWS % 1500)
    database = open(engine, path)
    script.each do |sql, expected|
      code = database.exec(sql)
      raise "#{engine}: #{sql[0, 120]} gave #{code} (#{database.error_message}), not #{expected}" unless code == expected
    end
    database.close
    database = open(engine, path)
    list = [] of String
    {"SELECT id, payload FROM entries ORDER BY id", "PRAGMA integrity_check"}.each do |sql|
      code, statement = database.prepare(sql)
      raise "#{engine}: #{sql} #{code}" unless code == Engine::OK_CODE
      while statement.step == Engine::ROW_CODE
        list << (0...statement.column_count).join(",") { |column| statement.column_text(column) }
      end
      statement.finalize_statement
    end
    database.close
    File.exists?("#{path}-journal").should be_false
    list.join('\n')
  end

  # Where two lists first differ, with the entries around it (nil when
  # they are equal), so a failure reads in one line.
  def self.first_difference(engine : Array, c_list : Array) : String?
    index = (0...Math.max(engine.size, c_list.size)).find { |position| engine[position]? != c_list[position]? }
    return unless index
    "entry #{index} of #{engine.size} (C: #{c_list.size}): engine #{engine[index, 3].inspect[0, 200]}, C #{c_list[index, 3].inspect[0, 200]}"
  end

  def self.both_roll_back(crash : Differential::Crash) : Nil
    c_rollback = Differential.roll_back(:libsqlite3, crash.database, crash.journal, scratch)
    engine_rollback = Differential.roll_back(:grant, crash.database, crash.journal, scratch)
    c_rollback.integrity.should eq("ok")
    engine_rollback.integrity.should eq("ok")
    c_rollback.journal_left.should be_false
    engine_rollback.journal_left.should be_false
    engine_rollback.database.should eq(c_rollback.database)
    engine_rollback.database.should eq(crash.before_transaction)
  end
end

describe "Grant::SQLiteEngine rollback journal with cache spills" do
  after_all do
    SQLiteEngineHotJournalDifferential.remove_writer
    FileUtils.rm_rf(JournalSpill.scratch)
  end

  {10, 37, 100}.each do |cache_size|
    it "spills at C's cache limit, giving C's journal segments (cache_size=#{cache_size}, updates by rowid)" do
      pending!("needs C SQLite 3.51.0 with upstream's page cache") unless JournalSpill.upstream_page_cache?
      setup = JournalSpill::PAGE_ROWS % 1200
      statements = JournalSpill.page_statements(1200)[0, 1200]
      engine = JournalSpill.segment_layout(:grant, setup, statements, cache_size)
      c_layout = JournalSpill.segment_layout(:libsqlite3, setup, statements, cache_size)
      engine.size.should be > 3
      JournalSpill.first_difference(engine, c_layout).should be_nil
    end

    it "spills at C's cache limit, giving C's journal segments, with appends and deletes (cache_size=#{cache_size})" do
      pending!("needs C SQLite 3.51.0 with upstream's page cache") unless JournalSpill.upstream_page_cache?
      setup = JournalSpill::PAGE_ROWS % 1200
      statements = JournalSpill.page_statements(1200)
      engine = JournalSpill.segment_layout(:grant, setup, statements, cache_size)
      c_layout = JournalSpill.segment_layout(:libsqlite3, setup, statements, cache_size)
      JournalSpill.first_difference(engine, c_layout).should be_nil
    end
  end

  it "spills where the linked C library does with this platform's page cache defaults" do
    pending!("needs C SQLite 3.51.0 with this platform's page cache defaults") unless SQLiteEngineReferenceLibrary.linked? && JournalSpill.same_cache_defaults?
    setup = JournalSpill::PAGE_ROWS % 2600
    statements = JournalSpill.page_statements(2600)[0, 2600]
    engine = JournalSpill.segment_layout(:grant, setup, statements, 0, pragmas: "")
    c_layout = JournalSpill.segment_layout(:libsqlite3, setup, statements, 0, pragmas: "")
    JournalSpill.first_difference(engine, c_layout).should be_nil
    {% if flag?(:darwin) %}
      # Apple's build holds 20,000 pages before it spills.
      engine.should be_empty
    {% else %}
      engine.size.should be > 3
    {% end %}
  end

  it "spills where C does when cache_spill lies past the cache size (cache_size=2000, cache_spill=2500)" do
    pending!("needs C SQLite 3.51.0") unless SQLiteEngineReferenceLibrary.linked?
    setup = JournalSpill::PAGE_ROWS % 3500
    statements = JournalSpill.page_statements(3500)[0, 3500]
    pragmas = "PRAGMA cache_size=2000; PRAGMA cache_spill=2500;"
    engine = JournalSpill.segment_layout(:grant, setup, statements, 2000, pragmas: pragmas)
    c_layout = JournalSpill.segment_layout(:libsqlite3, setup, statements, 2000, pragmas: pragmas)
    JournalSpill.first_difference(engine, c_layout).should be_nil
    engine.should eq([2498_u32])
  end

  it "spills nothing with cache_spill off" do
    setup = JournalSpill::PAGE_ROWS % 600
    statements = JournalSpill.page_statements(600)[0, 600]
    pragmas = "PRAGMA cache_size=10; PRAGMA cache_spill=1; PRAGMA cache_spill=off;"
    JournalSpill.segment_layout(:grant, setup, statements, 10, pragmas: pragmas).should be_empty
    JournalSpill.segment_layout(:libsqlite3, setup, statements, 10, pragmas: pragmas).should be_empty
  end

  # Upstream's pager and Apple's build alike journal in 512-byte sectors
  # (setSectorSize with SQLITE_IOCAP_POWERSAFE_OVERWRITE), though Apple's
  # compile options list DEFAULT_SECTOR_SIZE=4096.
  it "writes the sector size into the journal header that the linked C library writes" do
    c_sector = JournalSpill.journal_sector_size(:libsqlite3)
    c_sector.should eq(512_u32)
    JournalSpill.journal_sector_size(:grant).should eq(c_sector)
  end

  {"FULL", "NORMAL", "OFF"}.each do |synchronous|
    it "leaves a hot journal of several segments that C and the engine both roll back (synchronous=#{synchronous})" do
      crash = JournalSpill.crash_after_spills(:grant, 3, synchronous)
      synced = crash.list_of_segments.count(&.synced?)
      synchronous == "OFF" ? crash.list_of_segments.size.should(eq(1)) : synced.should(be >= 3)
      JournalSpill.both_roll_back(crash)
    end

    it "rolls back C's hot journal of several segments as C does (synchronous=#{synchronous})" do
      crash = JournalSpill.crash_after_spills(:libsqlite3, 3, synchronous)
      JournalSpill.both_roll_back(crash)
    end
  end

  it "rolls back a transaction that spilled, leaving the database file as it was" do
    path = JournalSpill.fresh_database("rollback.db", JournalSpill::INDEXED_ROWS % 2000)
    before = JournalSpill.read(path)
    database = JournalSpill.open(:grant, path)
    JournalSpill.run(database, "PRAGMA cache_size=10; PRAGMA cache_spill=1; BEGIN")
    JournalSpill.indexed_statements(300, 2000).each { |sql| JournalSpill.run(database, sql) }
    JournalSpill.read(path).should_not eq(before)
    JournalSpill.run(database, "ROLLBACK")
    JournalSpill.read(path).should eq(before)
    File.exists?("#{path}-journal").should be_false
    JournalSpill.run(database, "INSERT INTO entries (payload) VALUES ('after')")
    database.close
  end

  it "reads a changed table page from the database file once, though it spills and changes again" do
    file_system = SQLiteEngineCountingFileSystem.new
    database = Grant::SQLiteEngine::Database.open("spill_reads.db", read_write: true, file_system: file_system)
    database.create_table("CREATE TABLE entries (id INTEGER PRIMARY KEY, payload TEXT)")
    database.transaction do |writer|
      (1_i64..3_000_i64).each { |rowid| writer.insert("entries", rowid, [rowid, "p" * 200] of Grant::SQLiteEngine::Value) }
    end
    database.close
    # A 20-page clean cache, emptied as it fills, and spills at C's limit
    # for a 10-page cache: each pass changes every leaf again after it
    # spilled and left the clean cache.
    database = Grant::SQLiteEngine::Database.open("spill_reads.db", read_write: true, cache_pages: 20, file_system: file_system)
    database.pager.cache_size = 10_i64
    database.pager.cache_spill_size = 1_i64
    file_system.list_of_database_read_offsets.clear
    database.transaction do |writer|
      3.times do |pass|
        (1_i64..3_000_i64).step(5) { |rowid| writer.update("entries", rowid, [rowid, pass.to_s * 200] of Grant::SQLiteEngine::Value) }
      end
    end
    file_system.list_of_sync_calls.count(&.kind.journal?).should be > 4
    page = Bytes.new(database.pager.page_size)
    file = file_system.open("spill_reads.db")
    list_of_leaves_read_again = file_system.list_of_database_read_offsets.tally.select do |offset, reads|
      file.read_at(offset, page)
      # 0x0d: a table b-tree leaf (page 1 starts with the file header).
      reads > 1 && offset > 0 && page[0] == 0x0d
    end
    list_of_leaves_read_again.should be_empty
    database.close
  end

  it "gives C's rows after a savepoint and a failed statement are rolled back over spilled pages" do
    script = [
      {"PRAGMA cache_size=10", 0}, {"PRAGMA cache_spill=1", 0}, {"BEGIN", 0},
    ] of {String, Int32}
    JournalSpill.indexed_statements(60, 1500).each { |sql| script << {sql, 0} }
    script << {"SAVEPOINT inner_work", 0}
    JournalSpill.indexed_statements(120, 1500)[60..].each { |sql| script << {sql, 0} }
    script << {"ROLLBACK TO inner_work", 0}
    script << {"UPDATE entries SET payload = hex(zeroblob(150)) || (id + 100000) WHERE id <= 400", 0}
    # Fails at its last row (a duplicate payload), after many spills.
    script << {"UPDATE entries SET payload = CASE WHEN id = 1400 THEN hex(zeroblob(150)) || 100001 ELSE hex(zeroblob(150)) || (id + 200000) END WHERE id > 450", 19}
    script << {"RELEASE inner_work", 0}
    script << {"DELETE FROM entries WHERE id % 3 = 0", 0}
    script << {"COMMIT", 0}
    engine = JournalSpill.rows_after(:grant, script)
    JournalSpill.first_difference(engine.lines, JournalSpill.rows_after(:libsqlite3, script).lines).should be_nil
    engine.lines.last.should eq("ok")
  end
end
