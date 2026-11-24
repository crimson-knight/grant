module Grant::SQLiteEngine
  # The rollback journal of `journal_mode=DELETE` (fileformat2.html §3,
  # atomiccommit.html): a header, then the original image of every page a
  # transaction changes, each with a checksum. The journal's existence on
  # disk is what makes a half-written transaction roll back.
  module RollbackJournal
    MAGIC = Bytes[0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]

    # The header takes one sector. C SQLite's unix VFS reports 4,096-byte
    # sectors (SQLITE_DEFAULT_SECTOR_SIZE), and before it reads a journal's
    # header it ignores any journal shorter than that, so the engine writes
    # the same size.
    SECTOR_SIZE = 4_096

    # nRec of a journal whose record count is the file size's to tell.
    RECORD_COUNT_FROM_SIZE = 0xffff_ffff_u32

    # The journal of the database at *database_path*.
    def self.path_for(database_path : String) : String
      "#{database_path}-journal"
    end

    # Writes and syncs a journal holding *list_of_images* (page number and
    # original bytes), the way syncJournal does: the header (with a record
    # count of 0) and the records, a sync when *synchronous* is FULL or
    # EXTRA, then the record count, then a sync. Each sync is made in
    # *sync_mode*. With *synchronous* OFF nothing is synced, and the header
    # says from the start that the file's size tells the record count, as
    # C's header does when it will not be synced (writeJournalHdr).
    def self.write(journal : DatabaseFile, page_size : Int32, initial_page_count : UInt32, list_of_images : Array({UInt32, Bytes}), nonce : UInt32,
                   synchronous : Synchronous = Synchronous::Full, sync_mode : SyncMode = SyncMode::Normal) : Nil
      header = Bytes.new(SECTOR_SIZE)
      header.copy_from(MAGIC.to_unsafe, MAGIC.size)
      put_u32(header, 8, synchronous.off? ? RECORD_COUNT_FROM_SIZE : 0_u32)
      put_u32(header, 12, nonce)
      put_u32(header, 16, initial_page_count)
      put_u32(header, 20, SECTOR_SIZE.to_u32)
      put_u32(header, 24, page_size.to_u32)
      journal.truncate(0)
      journal.write_at(0, header)
      offset = SECTOR_SIZE.to_i64
      record = Bytes.new(page_size + 8)
      list_of_images.each do |page_number, image|
        put_u32(record, 0, page_number)
        (record + 4).copy_from(image.to_unsafe, page_size)
        put_u32(record, page_size + 4, checksum(nonce, image))
        journal.write_at(offset, record)
        offset += record.size
      end
      return if synchronous.off?
      journal.sync(sync_mode) if synchronous >= Synchronous::Full
      count = Bytes.new(12)
      count.copy_from(MAGIC.to_unsafe, MAGIC.size)
      put_u32(count, 8, list_of_images.size.to_u32)
      journal.write_at(0, count)
      journal.sync(sync_mode)
    end

    # pager_cksum: the nonce plus every 200th byte of the page, counting
    # down from 200 bytes before its end.
    def self.checksum(nonce : UInt32, page : Bytes) : UInt32
      sum = nonce
      index = page.size - 200
      while index > 0
        sum &+= page[index]
        index -= 200
      end
      sum
    end

    # True when a journal must be rolled back before the database is read
    # (pagerHasHotJournal): it exists, is not empty, starts with a nonzero
    # byte, the database is not empty, and no other process holds RESERVED.
    def self.hot?(file_system : FileSystem, journal_path : String, database : DatabaseFile) : Bool
      return false unless file_system.exists?(journal_path)
      return false if database.size == 0
      return false if database.reserved_elsewhere?
      journal = file_system.open(journal_path)
      begin
        first = Bytes.new(1)
        journal.read_at(0, first) == 1 && first[0] != 0
      ensure
        journal.close
      end
    end

    # Copies the original pages back into *database*, as pager_playback
    # does: the file is cut to its size before the transaction, and records
    # are applied until the count runs out, a record is short, names page 0
    # or the lock-byte page, or fails its checksum. Syncs the database in
    # *sync_mode* (nil: no sync, as synchronous=OFF asks).
    def self.play_back(journal : DatabaseFile, database : DatabaseFile, sync_mode : SyncMode? = SyncMode::Normal) : Nil
      journal_size = journal.size
      return if journal_size < SECTOR_SIZE
      header = Bytes.new(28)
      return if journal.read_at(0, header) < 28
      return unless header[0, 8] == MAGIC
      record_count = get_u32(header, 8)
      nonce = get_u32(header, 12)
      initial_page_count = get_u32(header, 16)
      sector_size = get_u32(header, 20).to_i64
      page_size = get_u32(header, 24).to_i32
      unless power_of_two_between?(page_size.to_i64, Limits::MIN_PAGE_SIZE.to_i64, Limits::MAX_PAGE_SIZE.to_i64) &&
             power_of_two_between?(sector_size, 32_i64, 65_536_i64)
        raise CorruptDatabase.new("rollback journal header names page size #{page_size} and sector size #{sector_size}")
      end
      record_size = page_size.to_i64 + 8
      record_count = ((journal_size - sector_size) // record_size).to_u32 if record_count == RECORD_COUNT_FROM_SIZE
      resize(database, initial_page_count.to_i64 * page_size)
      lock_byte_page = (Pager::PENDING_BYTE_OFFSET // page_size + 1).to_u32
      offset = sector_size
      record = Bytes.new(record_size)
      record_count.times do
        break if offset + record_size > journal_size
        break if journal.read_at(offset, record) < record_size
        offset += record_size
        page_number = get_u32(record, 0)
        break if page_number == 0 || page_number == lock_byte_page
        image = record[4, page_size]
        break unless checksum(nonce, image) == get_u32(record, page_size + 4)
        next if page_number > initial_page_count
        database.write_at((page_number.to_i64 - 1) * page_size, image)
      end
      database.sync(sync_mode) if sync_mode
    end

    # pager_truncate: cut the file, or grow it to the size with a write at
    # its last page.
    private def self.resize(database : DatabaseFile, size : Int64) : Nil
      current = database.size
      if current > size
        database.truncate(size)
      elsif current < size
        database.write_at(size - 1, Bytes.new(1))
      end
    end

    private def self.power_of_two_between?(value : Int64, minimum : Int64, maximum : Int64) : Bool
      value >= minimum && value <= maximum && (value & (value - 1)) == 0
    end

    protected def self.put_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
      bytes[offset] = (value >> 24).to_u8!
      bytes[offset + 1] = (value >> 16).to_u8!
      bytes[offset + 2] = (value >> 8).to_u8!
      bytes[offset + 3] = value.to_u8!
    end

    protected def self.get_u32(bytes : Bytes, offset : Int32) : UInt32
      (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) | (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3]
    end
  end
end
