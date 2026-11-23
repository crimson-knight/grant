require "../../../../src/grant/sqlite_engine"

# Mutates database images (byte flips, truncation, page swaps and copies,
# zeroed pages, edge values in header fields, damaged WAL frames) and reads
# each mutant completely. A mutant must read cleanly or raise one of the
# engine's named errors; anything else, a case slower than one second, or
# heap growth over 64 MiB is a failure.
class SQLiteEngineDamageFuzzer
  MAX_CASE_SECONDS = 1.0
  MAX_HEAP_GROWTH  = 64_i64 * 1024 * 1024

  record Seed, fixture : String, database : Bytes, wal : Bytes?

  record Failure, case_number : Int32, fixture : String, mutation : String, detail : String, database : Bytes, wal : Bytes?

  getter cases_run = 0
  getter clean_reads = 0
  getter corrupt_database_raised = 0
  getter other_named_errors = Hash(String, Int32).new(0)
  getter list_of_failures = [] of Failure
  getter slowest_case_seconds = 0.0
  getter slowest_case = ""
  getter largest_heap_growth = 0_i64

  def initialize(@list_of_seeds : Array(Seed), @seed : Int64)
    @random = Random.new(@seed)
  end

  def run(case_count : Int32) : Nil
    baseline = GC.stats.heap_size.to_i64
    case_count.times do |case_number|
      source = @list_of_seeds.sample(@random)
      database = source.database.dup
      wal = source.wal.try(&.dup)
      mutation = mutate(database, wal)
      database = truncate(database) if mutation == "truncate"
      started = Time.instant
      outcome = read_completely(database, wal)
      elapsed = (Time.instant - started).total_seconds
      @cases_run += 1
      if elapsed > @slowest_case_seconds
        @slowest_case_seconds = elapsed
        @slowest_case = "#{source.fixture} #{mutation}"
      end
      growth = GC.stats.heap_size.to_i64 - baseline
      @largest_heap_growth = growth if growth > @largest_heap_growth
      if outcome.is_a?(Exception)
        @list_of_failures << Failure.new(case_number, source.fixture, mutation, "#{outcome.class}: #{outcome.message} at #{outcome.backtrace?.try(&.first(4).join(" < "))}", database, wal)
      elsif elapsed > MAX_CASE_SECONDS
        @list_of_failures << Failure.new(case_number, source.fixture, mutation, "took #{elapsed.round(3)} s", database, wal)
      elsif growth > MAX_HEAP_GROWTH
        @list_of_failures << Failure.new(case_number, source.fixture, mutation, "heap grew #{growth // 1024 // 1024} MiB", database, wal)
      end
    end
  end

  # Returns nil after a clean read or a named error, and the exception for
  # anything else.
  private def read_completely(database_bytes : Bytes, wal_bytes : Bytes?) : Exception?
    database = Grant::SQLiteEngine::Database.from_bytes(database_bytes, wal_bytes)
    schema = database.schema
    schema.list_of_tables.each do |entry|
      rowids = [] of Int64
      database.each_row(entry) { |row| rowids << (row.rowid || 0_i64) }
      unless schema.table_definition(entry).without_rowid?
        rowids.first(3).each { |rowid| database.find_row(entry.object_name, rowid) }
      end
    end
    schema.list_of_indexes.each { |entry| database.each_index_entry(entry) { } }
    database.freelist
    database.pointer_map_entries
    @clean_reads += 1
    nil
  rescue error : Grant::SQLiteEngine::CorruptDatabase
    @corrupt_database_raised += 1
    nil
  rescue error : Grant::SQLiteEngine::Error
    @other_named_errors[error.class.name] += 1
    nil
  rescue error : Exception
    error
  end

  private def mutate(database : Bytes, wal : Bytes?) : String
    page_size = page_size_of(database)
    pages = Math.max(database.size // page_size, 1)
    case @random.rand(9)
    when 0
      @random.rand(1..8).times { flip(database, @random.rand(database.size)) }
      "flip bytes"
    when 1
      page = @random.rand(pages)
      header = page == 0 ? 100 : 0
      @random.rand(1..3).times { flip(database, page * page_size + header + @random.rand(Math.min(page_size - header, 40))) }
      "flip page header"
    when 2
      "truncate"
    when 3
      swap_pages(database, page_size, pages)
      "swap pages"
    when 4
      from = @random.rand(pages)
      to = @random.rand(pages)
      (database + to * page_size).copy_from((database + from * page_size).to_unsafe, Math.min(page_size, database.size - Math.max(from, to) * page_size))
      "copy page"
    when 5
      page = @random.rand(pages)
      (database + page * page_size)[0, Math.min(page_size, database.size - page * page_size)].fill(0_u8)
      "zero page"
    when 6
      edge_value(database, page_size, pages)
      "edge value"
    when 7
      if wal && wal.size > 0
        @random.rand(1..6).times { flip(wal, @random.rand(wal.size)) }
        "flip WAL bytes"
      else
        flip(database, @random.rand(database.size))
        "flip byte"
      end
    else
      page = @random.rand(pages)
      start = page * page_size + @random.rand(page_size)
      @random.rand(1..12).times { |offset| database[start + offset] = 0xff_u8 if start + offset < database.size }
      "long varints"
    end
  end

  private def truncate(database : Bytes) : Bytes
    database[0, @random.rand(database.size)]
  end

  private def flip(bytes : Bytes, offset : Int32) : Nil
    bytes[offset] ^= (1_u8 << @random.rand(8)) | (@random.rand(4) == 0 ? 0xff_u8 : 0_u8)
  end

  private def swap_pages(database : Bytes, page_size : Int32, pages : Int32) : Nil
    first = @random.rand(pages)
    second = @random.rand(pages)
    return if first == second || (Math.max(first, second) + 1) * page_size > database.size
    copy = database[first * page_size, page_size].dup
    (database + first * page_size).copy_from((database + second * page_size).to_unsafe, page_size)
    (database + second * page_size).copy_from(copy.to_unsafe, page_size)
  end

  # Writes 0, 1, the page count, the page count plus one or all ones into a
  # four-byte field of a page header, a cell, or the database header.
  private def edge_value(database : Bytes, page_size : Int32, pages : Int32) : Nil
    value = [0_u32, 1_u32, pages.to_u32, pages.to_u32 + 1, UInt32::MAX, 0x7fffffff_u32].sample(@random)
    page = @random.rand(pages)
    offset = @random.rand(3) == 0 ? 28 + @random.rand(18) * 4 : page * page_size + @random.rand(page_size - 4)
    return if offset + 4 > database.size
    IO::ByteFormat::BigEndian.encode(value, database[offset, 4])
  end

  private def page_size_of(database : Bytes) : Int32
    return 512 if database.size < 18
    raw = (database[16].to_i32 << 8) | database[17]
    raw = 65_536 if raw == 1
    raw >= 512 && raw <= 65_536 && (raw & (raw - 1)) == 0 ? raw : 512
  end
end
