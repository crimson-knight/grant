require "spec"
require "../../../src/grant/sqlite_engine"

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

describe "the SQLite engine's commit path" do
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

describe "the SQLite engine's database file writes" do
  it "writes a run of buffers with write_run_at exactly as one write_at per buffer, past the vector limit" do
    random = Random.new(20261127)
    list_of_buffers = Array(Bytes).new(2_600) { Bytes.new(random.rand(1..700)) { random.rand(UInt8) } }
    directory = Path[Dir.tempdir] / "grant-sqlite-engine-runs-#{Process.pid}"
    Dir.mkdir_p(directory)
    batched_path = (directory / "batched.bin").to_s
    single_path = (directory / "single.bin").to_s
    File.delete?(batched_path)
    File.delete?(single_path)
    batched = Grant::SQLiteEngine::PosixFile.new(batched_path)
    single = Grant::SQLiteEngine::PosixFile.new(single_path)
    batched.write_at(0_i64, Bytes.new(64, 9_u8))
    single.write_at(0_i64, Bytes.new(64, 9_u8))
    batched.write_run_at(37_i64, list_of_buffers)
    offset = 37_i64
    list_of_buffers.each do |buffer|
      single.write_at(offset, buffer)
      offset += buffer.size
    end
    batched.close
    single.close
    File.read(batched_path).should eq(File.read(single_path))
    File.size(batched_path).should eq(37 + list_of_buffers.sum(&.size))
  end

  it "commits runs of changed pages that read back as C reads them" do
    path = (Path[Dir.tempdir] / "grant-sqlite-engine-runs-#{Process.pid}-commit.db").to_s
    File.delete?(path)
    File.delete?("#{path}-journal")
    database = Grant::SQLiteEngine::Database.open(path, read_write: true, page_size: 512)
    database.create_table("CREATE TABLE t(id INTEGER PRIMARY KEY, body TEXT)")
    database.transaction do |writer|
      (1_i64..3_000_i64).each { |rowid| writer.insert("t", nil, [nil, "row #{rowid} #{"b" * (rowid % 200)}"] of Grant::SQLiteEngine::Value) }
    end
    database.transaction do |writer|
      (1_i64..3_000_i64).step(3).each { |rowid| writer.delete("t", rowid) }
      (2_i64..3_000_i64).step(7).each { |rowid| writer.update("t", rowid, [rowid, "new #{rowid}"] of Grant::SQLiteEngine::Value) }
    end
    database.close
    output = IO::Memory.new
    Process.run("sqlite3", [path, "PRAGMA integrity_check; SELECT count(*), sum(length(body)) FROM t;"], output: output).success?.should be_true
    expected = (1..3_000).reject { |rowid| rowid % 3 == 1 }.sum { |rowid| (rowid - 2) % 7 == 0 ? "new #{rowid}".size : "row #{rowid} #{"b" * (rowid % 200)}".size }
    output.to_s.should eq("ok\n2000|#{expected}\n")
  end
end
