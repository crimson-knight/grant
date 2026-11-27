module Grant::SQLiteEngine
  # The rollback journal of `journal_mode=DELETE` (fileformat2.html §3,
  # atomiccommit.html): a header, then the original image of every page a
  # transaction changes, each with a checksum. The journal's existence on
  # disk is what makes a half-written transaction roll back.
  module RollbackJournal
    MAGIC = Bytes[0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]

    # The header takes one sector. C SQLite's unix VFS reports 4,096-byte
    # sectors, but its pager journals in 512-byte ones when the file system
    # promises powersafe overwrite, as the unix VFS does by default
    # (setSectorSize, SQLITE_POWERSAFE_OVERWRITE), so the engine writes the
    # same 512-byte header. A reader takes the sector size from the header.
    SECTOR_SIZE = 512

    # The most page records gathered into one write: the header and the
    # records go to the file in as few writes as this allows.
    RECORDS_PER_WRITE = 64

    # nRec of a journal whose record count is the file size's to tell.
    RECORD_COUNT_FROM_SIZE = 0xffff_ffff_u32

    # The journal of the database at *database_path*.
    def self.path_for(database_path : String) : String
      "#{database_path}-journal"
    end

    # Writes and syncs a journal holding *list_of_images* (page number and
    # original bytes) into the empty file *journal* (from
    # `FileSystem#create_journal`), the way syncJournal does: the header
    # (with a record count of 0) and the records, a sync when *synchronous*
    # is FULL or EXTRA, then the record count, then a sync. Each sync is
    # made in *sync_mode*. With *synchronous* OFF nothing is synced, and the
    # header says from the start that the file's size tells the record
    # count, as C's header does when it will not be synced
    # (writeJournalHdr). The header and the records go out together, up to
    # `RECORDS_PER_WRITE` records a write.
    #
    # The writes are gathered in *write_buffer*, which a caller keeps from
    # one commit to the next so a commit allocates nothing.
    def self.write(journal : DatabaseFile, page_size : Int32, initial_page_count : UInt32, list_of_images : Array({UInt32, Bytes}), nonce : UInt32,
                   synchronous : Synchronous = Synchronous::Full, sync_mode : SyncMode = SyncMode::Normal,
                   write_buffer : WriteBuffer = WriteBuffer.new) : Nil
      record_size = page_size + 8
      buffer = write_buffer.take(SECTOR_SIZE + record_size * Math.min(list_of_images.size, RECORDS_PER_WRITE))
      # The header sector's bytes past its fields stay zero, as C's do.
      buffer.to_unsafe.clear(SECTOR_SIZE)
      buffer.copy_from(MAGIC.to_unsafe, MAGIC.size)
      put_u32(buffer, 8, synchronous.off? ? RECORD_COUNT_FROM_SIZE : 0_u32)
      put_u32(buffer, 12, nonce)
      put_u32(buffer, 16, initial_page_count)
      put_u32(buffer, 20, SECTOR_SIZE.to_u32)
      put_u32(buffer, 24, page_size.to_u32)
      file_offset = 0_i64
      filled = SECTOR_SIZE
      list_of_images.each do |page_number, image|
        if filled + record_size > buffer.size
          journal.write_at(file_offset, buffer[0, filled])
          file_offset += filled
          filled = 0
        end
        raise ArgumentError.new("page image of #{image.size} bytes for #{page_size}-byte pages") unless image.size == page_size
        put_u32(buffer, filled, page_number)
        (buffer.to_unsafe + filled + 4).copy_from(image.to_unsafe, page_size)
        put_u32(buffer, filled + 4 + page_size, checksum(nonce, image))
        filled += record_size
      end
      journal.write_at(file_offset, buffer[0, filled])
      return if synchronous.off?
      journal.sync(sync_mode) if synchronous >= Synchronous::Full
      # The records are on their way to the disk; the buffer's first bytes
      # carry the record count now.
      count = buffer[0, 12]
      put_u32(count, 8, list_of_images.size.to_u32)
      journal.write_at(0, count)
      journal.sync(sync_mode)
    end

    # pager_cksum: the nonce plus every 200th byte of the page, counting
    # down from 200 bytes before its end.
    def self.checksum(nonce : UInt32, page : Bytes) : UInt32
      sum = nonce
      bytes = page.to_unsafe
      index = page.size - 200
      while index > 0
        sum &+= bytes[index]
        index -= 200
      end
      sum
    end

    # The bytes a journal is written from, kept between commits (a fresh
    # buffer per commit is a large allocation, and large allocations are
    # what start the garbage collector). It holds at most a header and
    # `RECORDS_PER_WRITE` records.
    class WriteBuffer
      @bytes = Bytes.empty

      # *size* bytes of the kept buffer, which grows to hold them. Their
      # contents are what the last write left.
      def take(size : Int32) : Bytes
        @bytes = Bytes.new(size) if @bytes.size < size
        @bytes[0, size]
      end
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
    # does, segment by segment. A journal holds one segment (a header and
    # its records) for each time the transaction synced it, which C does
    # before every spill of dirty pages to the database file
    # (readJournalHdr):
    #
    # * Each header starts at the next multiple of the sector size the
    #   first header names, and must start with the magic; a header that
    #   does not fit in the file, or lacks the magic, ends the playback.
    # * The first header's page and sector sizes must be powers of two in
    #   range, or nothing is played back; its page count is the size the
    #   file is cut or grown to, and the last page a record may restore.
    #   Later headers' sizes and page counts are not read.
    # * A record count of 0xffffffff means the rest of the file is records
    #   (counted from the file size past one header, as C counts); 0 means
    #   the segment has none, and the next header follows.
    # * Each record is checked against its own segment's nonce. Playback
    #   ends at a record cut short, or one naming page 0 or the lock-byte
    #   page, or (for a page within the original count) one whose checksum
    #   fails; a record past the original count is skipped unchecked.
    # * Every record is written, so a page journaled twice ends with its
    #   later image, as C's main-journal playback (no pDone) leaves it.
    #
    # Syncs the database in *sync_mode* (nil: no sync, as synchronous=OFF
    # asks).
    def self.play_back(journal : DatabaseFile, database : DatabaseFile, sync_mode : SyncMode? = SyncMode::Normal) : Nil
      play_back_segments(journal, database)
      database.sync(sync_mode) if sync_mode
    end

    private def self.play_back_segments(journal : DatabaseFile, database : DatabaseFile) : Nil
      journal_size = journal.size
      header = Bytes.new(28)
      header_size = SECTOR_SIZE.to_i64
      page_size = 0
      initial_page_count = 0_u32
      lock_byte_page = 0_u32
      record = Bytes.empty
      offset = 0_i64
      loop do
        offset = next_header_offset(offset, header_size)
        return if offset + header_size > journal_size
        return if journal.read_at(offset, header) < 28
        return unless header[0, 8] == MAGIC
        record_count = get_u32(header, 8)
        nonce = get_u32(header, 12)
        if offset == 0
          sector_size = get_u32(header, 20).to_i64
          page_size = get_u32(header, 24).to_i32
          return unless power_of_two_between?(page_size.to_i64, Limits::MIN_PAGE_SIZE.to_i64, Limits::MAX_PAGE_SIZE.to_i64) &&
                        power_of_two_between?(sector_size, 32_i64, 65_536_i64)
          header_size = sector_size
          initial_page_count = get_u32(header, 16)
          lock_byte_page = (Pager::PENDING_BYTE_OFFSET // page_size + 1).to_u32
          record = Bytes.new(page_size + 8)
        end
        offset += header_size
        record_size = record.size.to_i64
        record_count = ((journal_size - header_size) // record_size).to_u32 if record_count == RECORD_COUNT_FROM_SIZE
        resize(database, initial_page_count.to_i64 * page_size, page_size) if offset == header_size
        record_count.times do
          return if offset + record_size > journal_size
          return if journal.read_at(offset, record) < record_size
          offset += record_size
          page_number = get_u32(record, 0)
          return if page_number == 0 || page_number == lock_byte_page
          next if page_number > initial_page_count
          image = record[4, page_size]
          return unless checksum(nonce, image) == get_u32(record, page_size + 4)
          database.write_at((page_number.to_i64 - 1) * page_size, image)
        end
      end
    end

    # journalHdrOffset: the first multiple of *header_size* at or past
    # *offset*.
    private def self.next_header_offset(offset : Int64, header_size : Int64) : Int64
      offset == 0 ? 0_i64 : ((offset - 1) // header_size + 1) * header_size
    end

    # pager_truncate: cut the file, or grow it to the size with a page of
    # zeros at its end when it is at least a page short.
    private def self.resize(database : DatabaseFile, size : Int64, page_size : Int32) : Nil
      current = database.size
      if current > size
        database.truncate(size)
      elsif current + page_size <= size
        database.write_at(size - page_size, Bytes.new(page_size))
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
