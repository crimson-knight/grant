require "spec"
require "../../../src/grant/sqlite_engine"
require "../../support/sqlite_engine/counting_file_system"
require "file_utils"

# walformat.html §1's checksum, word by word, as the reference the engine's
# four-lane checksum must match bit for bit.
private def reference_wal_checksum(data : Bytes, seed : {UInt32, UInt32}) : {UInt32, UInt32}
  sum0, sum1 = seed
  (0...data.size // 8).each do |pair|
    first_word = IO::ByteFormat::LittleEndian.decode(UInt32, data[pair * 8, 4])
    second_word = IO::ByteFormat::LittleEndian.decode(UInt32, data[pair * 8 + 4, 4])
    sum0 = sum0 &+ first_word &+ sum1
    sum1 = sum1 &+ second_word &+ sum0
  end
  {sum0, sum1}
end

private def journal_bytes(file_system : Grant::SQLiteEngine::MemoryFileSystem, path : String) : Bytes
  journal = file_system.open(path)
  bytes = Bytes.new(journal.size)
  journal.read_at(0_i64, bytes)
  journal.close
  bytes
end

# A rollback-journal transaction that changes about 120 pages of
# entries_writeback.db in *file_system*, at *synchronous*.
private def change_many_pages(file_system : SQLiteEngineCountingFileSystem, synchronous : Grant::SQLiteEngine::Synchronous) : Nil
  database = Grant::SQLiteEngine::Database.open("entries_writeback.db", read_write: true, file_system: file_system,
    journal_mode: Grant::SQLiteEngine::JournalMode::Delete, synchronous: synchronous)
  database.create_table("CREATE TABLE entries (id INTEGER PRIMARY KEY, payload TEXT)")
  database.transaction do |writer|
    (1_i64..400_i64).each { |rowid| writer.insert("entries", rowid, [rowid, "p" * 1000] of Grant::SQLiteEngine::Value) }
  end
  file_system.list_of_writeback_requests.clear
  database.transaction do |writer|
    (1_i64..400_i64).each { |rowid| writer.update("entries", rowid, [rowid, "q" * 1000] of Grant::SQLiteEngine::Value) }
  end
  database.close
end

describe "the SQLite engine's commit path" do
  describe "DatabaseFile#start_writeback" do
    it "leaves a file's bytes as they are, for a range inside or past its end" do
      directory = File.tempname("start_writeback")
      Dir.mkdir_p(directory)
      begin
        path = File.join(directory, "file.db")
        file = Grant::SQLiteEngine::PosixFile.new(path)
        bytes = Bytes.new(10_000) { |index| (index % 251).to_u8 }
        file.write_at(0_i64, bytes)
        file.start_writeback(0_i64, bytes.size.to_i64)
        file.start_writeback(8_192_i64, 65_536_i64)
        file.sync(Grant::SQLiteEngine::SyncMode::Normal)
        read_back = Bytes.new(bytes.size)
        file.read_at(0_i64, read_back).should eq(bytes.size)
        read_back.should eq(bytes)
        file.size.should eq(bytes.size)
        file.close
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "is asked for every journal write and every 64 commit pages, each over bytes already written" do
      file_system = SQLiteEngineCountingFileSystem.new
      change_many_pages(file_system, Grant::SQLiteEngine::Synchronous::Full)
      list_of_requests = file_system.list_of_writeback_requests
      journal_requests = list_of_requests.select(&.kind.journal?)
      database_requests = list_of_requests.select(&.kind.database?)
      journal_requests.size.should be > 0
      database_requests.size.should be > 0
      list_of_requests.each { |request| (request.offset + request.length).should be <= request.written_size }
      # Each journal request covers the write just made, so together they
      # cover the journal from its first byte, write after write.
      journal_requests.first.offset.should eq(0)
      journal_requests.each_cons_pair { |earlier, later| later.offset.should be >= earlier.offset + earlier.length }
      database_requests.each { |request| (request.length % 4096).should eq(0) }
    end

    it "is never asked for when synchronous is OFF" do
      file_system = SQLiteEngineCountingFileSystem.new
      change_many_pages(file_system, Grant::SQLiteEngine::Synchronous::Off)
      file_system.list_of_writeback_requests.should be_empty
    end
  end

  describe "WriteAheadLog.checksum" do
    it "matches the word-by-word checksum for every page size and odd lengths" do
      random = Random.new(20261126)
      [8, 24, 504, 512, 520, 1024, 2048, 4096, 4104, 8192, 16384, 32768, 65536].each do |size|
        3.times do
          data = Bytes.new(size) { random.rand(UInt8) }
          seed = {random.rand(UInt32), random.rand(UInt32)}
          Grant::SQLiteEngine::WriteAheadLog.checksum(data, seed).should eq(reference_wal_checksum(data, seed))
        end
      end
    end

    it "matches it for pages of all ones, where the sums wrap on every word" do
      data = Bytes.new(4096, 0xff_u8)
      seed = {0xffff_ffff_u32, 0xffff_ffff_u32}
      Grant::SQLiteEngine::WriteAheadLog.checksum(data, seed).should eq(reference_wal_checksum(data, seed))
    end
  end

  describe Grant::SQLiteEngine::PageTable do
    it "behaves as a Hash under random puts, lookups, deletes and clears" do
      random = Random.new(7)
      table = Grant::SQLiteEngine::PageTable.new
      model = {} of UInt32 => Bytes
      20_000.times do |step|
        page_number = random.rand(1_u32..(step < 10_000 ? 300_u32 : 5_000_u32))
        case random.rand(10)
        when 0, 1, 2, 3
          buffer = Bytes.new(4, page_number.to_u8!)
          table[page_number] = buffer
          model[page_number] = buffer
        when 4, 5
          table.delete(page_number).should eq(model.delete(page_number))
        when 6
          if random.rand(200) == 0
            table.clear
            model.clear
          end
        else
          table[page_number]?.should eq(model[page_number]?)
          table.has_key?(page_number).should eq(model.has_key?(page_number))
        end
        table.size.should eq(model.size)
      end
      seen = {} of UInt32 => Bytes
      table.each { |page_number, buffer| seen[page_number] = buffer }
      seen.should eq(model)
      keys = [] of UInt32
      table.each_key { |page_number| keys << page_number }
      keys.sort.should eq(model.keys.sort!)
    end

    it "drops the entries reject! picks and keeps the others reachable" do
      table = Grant::SQLiteEngine::PageTable.new
      (1_u32..100_u32).each { |page_number| table[page_number] = Bytes.new(1, page_number.to_u8!) }
      table.reject! { |page_number, _| page_number > 40 }
      table.size.should eq(40)
      (1_u32..40_u32).each { |page_number| table[page_number]?.should eq(Bytes.new(1, page_number.to_u8!)) }
      (41_u32..100_u32).each { |page_number| table[page_number]?.should be_nil }
    end

    it "refuses page number 0, which marks an empty slot" do
      expect_raises(ArgumentError) { Grant::SQLiteEngine::PageTable.new[0_u32] = Bytes.new(1) }
    end
  end

  describe "RollbackJournal.write with a kept WriteBuffer" do
    it "writes the same bytes as a fresh buffer, commit after commit" do
      random = Random.new(11)
      kept = Grant::SQLiteEngine::RollbackJournal::WriteBuffer.new
      [70, 3, 1, 65, 2].each_with_index do |image_count, commit|
        list_of_images = (1..image_count).map { |page_number| {page_number.to_u32, Bytes.new(1024) { random.rand(UInt8) }} }
        file_system = Grant::SQLiteEngine::MemoryFileSystem.new
        Grant::SQLiteEngine::RollbackJournal.write(file_system.open("fresh-journal"), 1024, 90_u32, list_of_images, commit.to_u32)
        Grant::SQLiteEngine::RollbackJournal.write(file_system.open("kept-journal"), 1024, 90_u32, list_of_images, commit.to_u32,
          write_buffer: kept)
        journal_bytes(file_system, "kept-journal").should eq(journal_bytes(file_system, "fresh-journal"))
      end
    end
  end
end
