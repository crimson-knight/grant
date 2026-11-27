module Grant::SQLiteEngine
  # PRAGMA synchronous (pragma.html#pragma_synchronous). In WAL mode, FULL
  # and EXTRA sync the WAL at every commit; NORMAL syncs only at a
  # checkpoint (and when a WAL is started over); OFF never syncs.
  enum Synchronous
    Off
    Normal
    Full
    Extra
  end

  # The modes of `PRAGMA wal_checkpoint` (sqlite3_wal_checkpoint_v2).
  enum CheckpointMode
    Passive
    Full
    Restart
    Truncate
  end

  # What a checkpoint did, as `PRAGMA wal_checkpoint` reports it: whether
  # it was stopped by another connection, the frames in the WAL, and the
  # frames copied into the database. Both counts are -1 when the database
  # is not in WAL mode or the checkpoint could not start.
  record CheckpointResult, busy : Bool, log_frames : Int32, checkpointed_frames : Int32

  # Raised when a connection reading an older snapshot tries to write after
  # another connection committed (SQLITE_BUSY_SNAPSHOT): waiting cannot
  # help, the transaction must start again.
  class BusySnapshot < Busy
    # SQLITE_BUSY_SNAPSHOT: SQLITE_BUSY | (2 << 8).
    EXTENDED_RESULT_CODE = 517

    def extended_result_code : Int32
      EXTENDED_RESULT_CODE
    end
  end

  # Waits for a lock the way C SQLite's default busy handler does
  # (sqliteDefaultBusyCallback): sleeps of 1, 2, 5, 10, 15, 20, 25, 25, 25,
  # 50, 50 and then 100 ms, until the timeout has passed.
  module BusyWait
    LIST_OF_DELAYS = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]
    # The milliseconds slept before each of those delays.
    LIST_OF_TOTALS = [0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228]

    # One busy handler with its count of calls (sqlite3's BusyHandler and
    # its nBusy): the waits of one operation share it, so together they
    # last no longer than the timeout.
    class Handler
      @count = 0

      def initialize(@timeout : Time::Span)
      end

      # Sleeps the next delay and returns true; returns false, without
      # sleeping, once the timeout is used up (or is zero: no handler).
      def waited_for_another_try? : Bool
        timeout = @timeout.total_milliseconds.to_i64
        return false unless timeout > 0
        last = LIST_OF_DELAYS.size - 1
        if @count <= last
          delay = LIST_OF_DELAYS[@count].to_i64
          prior = LIST_OF_TOTALS[@count].to_i64
        else
          delay = LIST_OF_DELAYS[last].to_i64
          prior = LIST_OF_TOTALS[last] + delay * (@count - last)
        end
        delay = timeout - prior if prior + delay > timeout
        return false unless delay > 0
        sleep delay.milliseconds
        @count += 1
        true
      end
    end

    # Yields until the block returns true or *timeout* runs out; returns
    # the block's last answer.
    def self.attempt(timeout : Time::Span?, & : -> Bool) : Bool
      return true if yield
      return false unless timeout
      handler = Handler.new(timeout)
      while handler.waited_for_another_try?
        return true if yield
      end
      false
    end

    # Yields until the block returns true or *handler* stops waiting (nil:
    # one try only); returns the block's last answer.
    def self.attempt(handler : Handler?, & : -> Bool) : Bool
      return true if yield
      return false unless handler
      while handler.waited_for_another_try?
        return true if yield
      end
      false
    end
  end

  # One connection's use of a database's write-ahead log (wal.c): the
  # `-wal` file in the format of fileformat2.html §4, the wal-index in the
  # `-shm` file in the layout of walformat.html, and the locks C SQLite
  # takes on it, so the engine and `sqlite3` processes read and write one
  # database together.
  #
  # A reader holds one read mark while it reads: the WAL frames up to that
  # mark are its snapshot. One writer at a time holds the WRITE lock and
  # appends the frames of a transaction, the last one marking the commit.
  # A checkpoint copies frames no reader still needs into the database.
  class WriteAheadLog
    MAGIC             = 0x377f0682_u32
    FORMAT_VERSION    =  3_007_000_u32
    HEADER_SIZE       =             32
    FRAME_HEADER_SIZE =             24
    # WAL_RETRY_PROTOCOL_LIMIT.
    RETRY_LIMIT = 100

    include WalIndexLayout

    # This connection's copy of the wal-index header (pWal->hdr): the
    # snapshot it reads.
    getter header = WalIndexHeader.new
    # The read mark this connection holds, or -1 when it is not reading.
    getter read_lock_index = -1
    getter? writing = false
    property synchronous : Synchronous
    # How a commit syncs the WAL (WAL_SYNC_FLAGS), from PRAGMA fullfsync.
    property sync_mode : SyncMode = SyncMode::Normal
    # How a checkpoint syncs the WAL and the database file, and how a new
    # WAL header is synced (CKPT_SYNC_FLAGS), from PRAGMA
    # checkpoint_fullfsync and fullfsync.
    property checkpoint_sync_mode : SyncMode = SyncMode::Normal

    @log : DatabaseFile
    @index : SharedMemory
    @log_path : String
    # The latest frame of each page among the WAL's committed frames, for
    # frames up to `@indexed_frames` of the WAL whose salts are
    # `@indexed_salts`.
    @frame_of_page = {} of UInt32 => UInt32
    @indexed_frames = 0_u32
    @indexed_salts = Bytes.new(8)
    # pWal->nCkpt: the checkpoint sequence this connection writes into a
    # new WAL header.
    @checkpoint_sequence = 0_u32
    @holds_checkpoint_lock = false
    @changed = false

    def self.path_for(database_path : String) : String
      "#{database_path}-wal"
    end

    def self.index_path_for(database_path : String) : String
      "#{database_path}-shm"
    end

    # Opens (creating) the `-wal` and `-shm` files of the database at
    # *database_path*.
    def initialize(@file_system : FileSystem, database_path : String, @synchronous : Synchronous)
      @log_path = WriteAheadLog.path_for(database_path)
      @log = @file_system.open(@log_path)
      @index = begin
        open_index(WriteAheadLog.index_path_for(database_path))
      rescue error
        @log.close
        raise error
      end
    end

    # Opens the wal-index. While another process holds its dead man switch
    # exclusively (it is truncating the file a crash left), C's first read
    # gets SQLITE_BUSY from xShmMap and tries again (WAL_RETRY in
    # walTryBeginRead); the open tries again on the same schedule.
    private def open_index(index_path : String) : SharedMemory
      attempt = 1
      loop do
        return @file_system.open_shared_memory(index_path)
      rescue Busy
        attempt += 1
        pause_before_retry(attempt)
      end
    end

    # walTryBeginRead's pause before try number *attempt*: none for the
    # first five, then 1 microsecond, then longer ones adding up to about
    # ten seconds before try 100 gives up (SQLITE_PROTOCOL).
    private def pause_before_retry(attempt : Int32) : Nil
      return unless attempt > 5
      raise Error.new("locking protocol (no WAL read mark after #{RETRY_LIMIT} tries)") if attempt > RETRY_LIMIT
      delay = attempt >= 10 ? (attempt - 9) * (attempt - 9) * 39 : 1
      sleep delay.microseconds
    end

    def reading? : Bool
      @read_lock_index >= 0
    end

    # The number of frames in the WAL as of this connection's snapshot.
    def frame_count : UInt32
      @header.max_frame
    end

    # The database size the snapshot records, or 0 when the WAL has none.
    def database_page_count : UInt32
      @header.database_page_count
    end

    # --- Reading -----------------------------------------------------------

    # sqlite3WalBeginReadTransaction: reads the wal-index header (running
    # recovery when it is missing or damaged) and takes a read mark.
    # Returns true when the snapshot differs from the previous one, so
    # cached pages are stale. Raises `Busy` while another connection runs
    # recovery.
    def begin_read : Bool
      raise Error.new("a WAL read is already open") if reading?
      @changed = false
      attempt = 1
      until try_begin_read(use_wal: false, attempt: attempt)
        attempt += 1
      end
      update_frame_map if @read_lock_index > 0
      @changed
    end

    def end_read : Nil
      return unless reading?
      @index.unlock(WalIndexLayout.read_lock(@read_lock_index))
      @read_lock_index = -1
    end

    # Reads the snapshot's copy of *page_number* into *buffer*; false when
    # the WAL holds none (or this reader uses the database file alone).
    def read_page(page_number : UInt32, buffer : Bytes) : Bool
      return false if @read_lock_index <= 0
      frame = @frame_of_page[page_number]?
      return false unless frame
      page_size = @header.page_size
      offset = frame_offset(frame, page_size) + FRAME_HEADER_SIZE
      if @log.read_at(offset, buffer[0, page_size]) < page_size
        raise CorruptDatabase.new("WAL frame #{frame} for page #{page_number} is truncated", page_number)
      end
      true
    end

    # walTryBeginRead: true once a read mark is held, false to try again.
    private def try_begin_read(use_wal : Bool, attempt : Int32) : Bool
      pause_before_retry(attempt)
      unless use_wal
        case read_index_header
        when .busy?
          return false unless @index.mapped_region_count > 0
          raise Busy.new("database is locked (another connection is recovering the WAL)") unless @index.lock_shared(RECOVER_LOCK)
          @index.unlock(RECOVER_LOCK)
          return false
        end
      end
      if !use_wal && backfilled_frames == @header.max_frame
        if @index.lock_shared(WalIndexLayout.read_lock(0))
          @index.barrier
          unless live_header == @header
            @index.unlock(WalIndexLayout.read_lock(0))
            return false
          end
          @read_lock_index = 0
          return true
        end
      end
      highest_mark = 0_u32
      highest_index = 0
      max_frame = @header.max_frame
      1.upto(READER_COUNT - 1) do |index|
        mark = read_mark(index)
        if highest_mark <= mark && mark <= max_frame
          highest_mark = mark
          highest_index = index
        end
      end
      if highest_mark < max_frame || highest_index == 0
        1.upto(READER_COUNT - 1) do |index|
          next unless @index.lock_exclusive(WalIndexLayout.read_lock(index))
          set_read_mark(index, max_frame)
          highest_mark = max_frame
          highest_index = index
          @index.unlock(WalIndexLayout.read_lock(index))
          break
        end
      end
      return false if highest_index == 0
      return false unless @index.lock_shared(WalIndexLayout.read_lock(highest_index))
      @index.barrier
      if read_mark(highest_index) != highest_mark || live_header != @header
        @index.unlock(WalIndexLayout.read_lock(highest_index))
        return false
      end
      @read_lock_index = highest_index
      true
    end

    enum HeaderRead
      Read
      Busy
    end

    # walIndexReadHdr: the header without a lock when both copies agree,
    # otherwise under the WRITE lock, rebuilding the index when it is still
    # damaged.
    private def read_index_header : HeaderRead
      return HeaderRead::Read if @index.map_region(0, grow: false) && try_header
      took_lock = !@writing
      if took_lock
        return HeaderRead::Busy unless @index.lock_exclusive(WRITE_LOCK)
      end
      begin
        @index.map_region(0, grow: true)
        unless try_header
          return HeaderRead::Busy unless recover
          @changed = true
        end
      ensure
        @index.unlock(WRITE_LOCK) if took_lock
      end
      if @header.version != WalIndexHeader::VERSION
        raise Error.new("unable to open database file (wal-index version #{@header.version})")
      end
      HeaderRead::Read
    end

    # walIndexTryHdr.
    private def try_header : Bool
      first = @first_header_copy
      @index.read_into(0, first)
      @index.barrier
      second = @second_header_copy
      @index.read_into(HEADER_COPY_TWO, second)
      return false unless first == second
      header = WalIndexHeader.new(first)
      return false unless header.valid?
      unless header == @header
        @changed = true
        @header = WalIndexHeader.new(first.dup)
      end
      true
    end

    # The header in the wal-index now, read into a buffer the next call
    # reuses: compare it or read a field, then let it go.
    private def live_header : WalIndexHeader
      @index.read_into(0, @live_header_copy)
      WalIndexHeader.new(@live_header_copy)
    end

    # Buffers the header reads above copy the wal-index header into.
    @first_header_copy = Bytes.new(WalIndexHeader::SIZE)
    @second_header_copy = Bytes.new(WalIndexHeader::SIZE)
    @live_header_copy = Bytes.new(WalIndexHeader::SIZE)

    # walIndexWriteHdr: the second copy first, then the first.
    private def write_index_header : Nil
      @header.seal
      @index.write_bytes(HEADER_COPY_TWO, @header.bytes)
      @index.barrier
      @index.write_bytes(0, @header.bytes)
    end

    private def backfilled_frames : UInt32
      @index.read_u32(BACKFILL_OFFSET)
    end

    private def read_mark(index : Int32) : UInt32
      @index.read_u32(WalIndexLayout.read_mark_offset(index))
    end

    private def set_read_mark(index : Int32, value : UInt32) : Nil
      @index.write_u32(WalIndexLayout.read_mark_offset(index), value)
    end

    # The page number frame *frame* holds, from the wal-index.
    # *mapped_region* names a region already mapped, which needs no new
    # look (a region stays mapped until the index closes).
    private def page_of_frame(frame : UInt32, mapped_region : Int32 = -1) : UInt32
      region = WalIndexLayout.region_of(frame)
      unless region == mapped_region || @index.map_region(region, grow: false)
        raise CorruptDatabase.new("the wal-index lacks region #{region}")
      end
      slot = frame - WalIndexLayout.first_frame_before(region)
      @index.read_u32(WalIndexLayout.page_array_offset(region) + (slot.to_i32 - 1) * 4)
    end

    # Brings the page-to-frame map up to the snapshot, starting over when
    # the WAL was started again since it was built.
    private def update_frame_map : Nil
      salts = @header.salt_bytes
      if salts != @indexed_salts || @header.max_frame < @indexed_frames
        @frame_of_page.clear
        @indexed_frames = 0_u32
        @indexed_salts = salts.dup
      end
      frame = @indexed_frames + 1
      mapped_region = -1
      while frame <= @header.max_frame
        @frame_of_page[page_of_frame(frame, mapped_region)] = frame
        mapped_region = WalIndexLayout.region_of(frame)
        frame += 1
      end
      @indexed_frames = @header.max_frame
    end

    # --- Writing -----------------------------------------------------------

    # sqlite3WalBeginWriteTransaction: takes the WRITE lock. When another
    # connection committed after this snapshot was taken, *refresh* takes a
    # new snapshot and returns true (cached pages are stale); otherwise
    # raises `BusySnapshot`. Raises `Busy` while another connection writes.
    def begin_write(refresh : Bool) : Bool
      raise Error.new("a WAL write needs a read snapshot") unless reading?
      raise Busy.new unless @index.lock_exclusive(WRITE_LOCK)
      @writing = true
      return false if live_header == @header
      unless refresh
        end_write
        raise BusySnapshot.new
      end
      end_read
      begin
        begin_read
      rescue error
        end_write
        raise error
      end
      true
    end

    def end_write : Nil
      return unless @writing
      @index.unlock(WRITE_LOCK)
      @writing = false
    end

    # walFrames for a commit: appends one frame per page of
    # *list_of_pages* (in page order; the last frame carries the commit
    # mark and *page_count*), syncing the WAL when synchronous is FULL,
    # then adds the frames to the wal-index and publishes the new header.
    def commit(list_of_pages : Array({UInt32, Bytes}), page_count : UInt32, page_size : Int32) : Nil
      raise Error.new("a WAL commit needs the WRITE lock") unless @writing
      return if list_of_pages.empty?
      restart_log
      if @header.max_frame == 0
        write_log_header(page_size)
      elsif @header.page_size != page_size
        raise CorruptDatabase.new("WAL page size #{@header.page_size} differs from the database page size #{page_size}")
      end
      frame_size = FRAME_HEADER_SIZE + page_size
      buffer = frame_buffer(frame_size * list_of_pages.size)
      checksum = @header.frame_checksum
      salts = @header.salt_bytes
      list_of_pages.each_with_index do |(page_number, image), position|
        frame = buffer[position * frame_size, frame_size]
        put_big_endian(frame, 0, page_number)
        put_big_endian(frame, 4, position == list_of_pages.size - 1 ? page_count : 0_u32)
        frame[8, 8].copy_from(salts)
        (frame + FRAME_HEADER_SIZE).copy_from(image.to_unsafe, page_size)
        checksum = WriteAheadLog.checksum(frame[0, 8], checksum)
        checksum = WriteAheadLog.checksum(frame[FRAME_HEADER_SIZE, page_size], checksum)
        put_big_endian(frame, 16, checksum[0])
        put_big_endian(frame, 20, checksum[1])
      end
      first_frame = @header.max_frame + 1
      @log.write_at(frame_offset(first_frame, page_size), buffer)
      @log.sync(@sync_mode) if @synchronous >= Synchronous::Full
      # A region of the wal-index, once mapped, stays mapped until the
      # index closes, so each region is mapped once for the whole commit.
      mapped_region = -1
      list_of_pages.each_with_index do |(page_number, _image), position|
        frame = first_frame + position
        region = WalIndexLayout.region_of(frame)
        unless region == mapped_region
          @index.map_region(region, grow: true)
          mapped_region = region
        end
        append_to_index(frame, page_number)
      end
      @header.page_size = page_size
      @header.max_frame = first_frame + list_of_pages.size - 1
      @header.change_count = @header.change_count &+ 1
      @header.database_page_count = page_count
      @header.frame_checksum = checksum
      write_index_header
      update_frame_map
    end

    # The frames of one commit are built in one buffer kept between commits:
    # a fresh one per commit is a large allocation, and large allocations
    # are what start the garbage collector. A commit larger than
    # FRAME_BUFFER_LIMIT gets a buffer of its own that is not kept.
    @frame_buffer = Bytes.empty
    FRAME_BUFFER_LIMIT = 1 << 20

    private def frame_buffer(size : Int32) : Bytes
      return Bytes.new(size) if size > FRAME_BUFFER_LIMIT
      @frame_buffer = Bytes.new(Math.min(Math.max(size, @frame_buffer.size * 2), FRAME_BUFFER_LIMIT)) if @frame_buffer.size < size
      @frame_buffer[0, size]
    end

    # walRestartLog: a writer that reads the database file alone (read mark
    # 0) after a checkpoint copied every frame starts the WAL over from its
    # first frame, unless a reader still uses it; then it takes a read mark
    # as any writer does.
    private def restart_log : Nil
      return unless @read_lock_index == 0
      if backfilled_frames > 0
        salt = Random.rand(UInt32)
        if @index.lock_exclusive(WalIndexLayout.read_lock(1), READER_COUNT - 1)
          restart_header(salt)
          @index.unlock(WalIndexLayout.read_lock(1), READER_COUNT - 1)
        end
      end
      @index.unlock(WalIndexLayout.read_lock(0))
      @read_lock_index = -1
      attempt = 1
      until try_begin_read(use_wal: true, attempt: attempt)
        attempt += 1
      end
    end

    # walRestartHdr.
    private def restart_header(salt : UInt32) : Nil
      @checkpoint_sequence &+= 1
      @header.max_frame = 0_u32
      salts = @header.salt_bytes.dup
      put_big_endian(salts, 0, get_big_endian(salts, 0) &+ 1)
      IO::ByteFormat::SystemEndian.encode(salt, salts[4, 4])
      @header.salt_bytes = salts
      write_index_header
      @index.write_u32(BACKFILL_OFFSET, 0_u32)
      @index.write_u32(BACKFILL_ATTEMPTED, 0_u32)
      set_read_mark(1, 0_u32)
      2.upto(READER_COUNT - 1) { |index| set_read_mark(index, READ_MARK_NOT_USED) }
    end

    # The 32-byte WAL header of fileformat2.html §4.1, synced unless
    # synchronous is OFF (ticket ff5be73dee).
    private def write_log_header(page_size : Int32) : Nil
      header = Bytes.new(HEADER_SIZE)
      put_big_endian(header, 0, MAGIC)
      put_big_endian(header, 4, FORMAT_VERSION)
      put_big_endian(header, 8, page_size.to_u32)
      put_big_endian(header, 12, @checkpoint_sequence)
      if @checkpoint_sequence == 0
        salts = Bytes.new(8)
        Random.new.random_bytes(salts)
        @header.salt_bytes = salts
      end
      header[16, 8].copy_from(@header.salt_bytes)
      checksum = WriteAheadLog.checksum(header[0, 24], {0_u32, 0_u32})
      put_big_endian(header, 24, checksum[0])
      put_big_endian(header, 28, checksum[1])
      @header.bytes[13] = 0_u8
      @header.frame_checksum = checksum
      @log.write_at(0, header)
      @log.sync(@checkpoint_sync_mode) unless @synchronous.off?
    end

    # walIndexAppend: the frame's page number into the region's array and
    # its index into the hash table; a region's first frame clears the
    # region, and leftovers of a writer that stopped midway are removed.
    # The frame's region is mapped already.
    private def append_to_index(frame : UInt32, page_number : UInt32) : Nil
      region = WalIndexLayout.region_of(frame)
      slot = (frame - WalIndexLayout.first_frame_before(region)).to_i32
      pages = WalIndexLayout.page_array_offset(region)
      hashes = WalIndexLayout.hash_table_offset(region)
      @index.zero(pages, hashes + HASH_SLOTS * 2 - pages) if slot == 1
      clean_up_hash if @index.read_u32(pages + (slot - 1) * 4) != 0
      key = WalIndexLayout.hash(page_number)
      collisions = slot
      while @index.read_u16(hashes + key * 2) != 0
        raise CorruptDatabase.new("wal-index hash table is full") if collisions == 0
        collisions -= 1
        key = (key + 1) & (HASH_SLOTS - 1)
      end
      @index.write_u32(pages + (slot - 1) * 4, page_number)
      @index.write_u16(hashes + key * 2, slot.to_u16)
    end

    # walCleanupHash: drops the entries past the last committed frame from
    # its region.
    private def clean_up_hash : Nil
      max_frame = @header.max_frame
      return if max_frame == 0
      region = WalIndexLayout.region_of(max_frame)
      limit = (max_frame - WalIndexLayout.first_frame_before(region)).to_i32
      hashes = WalIndexLayout.hash_table_offset(region)
      HASH_SLOTS.times do |slot|
        @index.write_u16(hashes + slot * 2, 0_u16) if @index.read_u16(hashes + slot * 2) > limit
      end
      start = WalIndexLayout.page_array_offset(region) + limit * 4
      @index.zero(start, hashes - start)
    end

    # --- Recovery ------------------------------------------------------------

    # walIndexRecover, with the WRITE lock held: rebuilds the wal-index from
    # the frames of the WAL file, up to the first frame whose salts or
    # checksum do not match, and publishes the last commit among them.
    # Returns false when another connection holds the locks recovery needs.
    private def recover : Bool
      first_lock = @holds_checkpoint_lock ? RECOVER_LOCK : CKPT_LOCK
      lock_count = WalIndexLayout.read_lock(0) - first_lock
      return false unless @index.lock_exclusive(first_lock, lock_count)
      begin
        @header = WalIndexHeader.new
        committed_checksum = {0_u32, 0_u32}
        size = @log.size
        if size > HEADER_SIZE
          committed_checksum = recover_frames(size)
        end
        @header.frame_checksum = committed_checksum
        write_index_header
        @index.write_u32(BACKFILL_OFFSET, 0_u32)
        @index.write_u32(BACKFILL_ATTEMPTED, @header.max_frame)
        set_read_mark(0, 0_u32)
        1.upto(READER_COUNT - 1) do |index|
          next unless @index.lock_exclusive(WalIndexLayout.read_lock(index))
          set_read_mark(index, index == 1 && @header.max_frame > 0 ? @header.max_frame : READ_MARK_NOT_USED)
          @index.unlock(WalIndexLayout.read_lock(index))
        end
      ensure
        @index.unlock(first_lock, lock_count)
      end
      true
    end

    # Reads the frames into the wal-index, region by region, through a
    # private copy of each region (as wal.c does); returns the checksum
    # after the last commit frame.
    private def recover_frames(size : Int64) : {UInt32, UInt32}
      committed = {0_u32, 0_u32}
      log_header = Bytes.new(HEADER_SIZE)
      return committed if @log.read_at(0, log_header) < HEADER_SIZE
      magic = get_big_endian(log_header, 0)
      page_size = get_big_endian(log_header, 8).to_i64
      valid_page_size = page_size >= Limits::MIN_PAGE_SIZE && page_size <= Limits::MAX_PAGE_SIZE && (page_size & (page_size - 1)) == 0
      return committed unless magic & 0xffff_fffe_u32 == MAGIC && valid_page_size
      big_endian = magic & 1 == 1
      @header.bytes[13] = big_endian ? 1_u8 : 0_u8
      @checkpoint_sequence = get_big_endian(log_header, 12)
      @header.salt_bytes = log_header[16, 8]
      checksum = WriteAheadLog.checksum(log_header[0, 24], {0_u32, 0_u32}, big_endian)
      return committed unless checksum == {get_big_endian(log_header, 24), get_big_endian(log_header, 28)}
      if get_big_endian(log_header, 4) != FORMAT_VERSION
        raise Error.new("unable to open database file (WAL format version #{get_big_endian(log_header, 4)})")
      end
      page_bytes = page_size.to_i32
      frame_size = FRAME_HEADER_SIZE + page_bytes
      last_frame = ((size - HEADER_SIZE) // frame_size).to_u32
      frame = Bytes.new(frame_size)
      salts = @header.salt_bytes
      stopped = false
      region = 0
      while region <= WalIndexLayout.region_of(last_frame) && !stopped
        private_region = Bytes.new(SharedMemory::REGION_SIZE)
        base = region == 0 ? INDEX_HEADER_SIZE : 0
        first = WalIndexLayout.first_frame_before(region) + 1
        last = Math.min(last_frame, WalIndexLayout.first_frame_before(region + 1))
        number = first
        while number <= last
          if @log.read_at(frame_offset(number, page_bytes), frame) < frame_size || frame[8, 8] != salts
            stopped = true
            break
          end
          page_number = get_big_endian(frame, 0)
          if page_number == 0
            stopped = true
            break
          end
          checksum = WriteAheadLog.checksum(frame[0, 8], checksum, big_endian)
          checksum = WriteAheadLog.checksum(frame[FRAME_HEADER_SIZE, page_bytes], checksum, big_endian)
          unless checksum == {get_big_endian(frame, 16), get_big_endian(frame, 20)}
            stopped = true
            break
          end
          append_to_private_region(private_region, base, (number - first + 1).to_i32, page_number)
          commit_page_count = get_big_endian(frame, 4)
          if commit_page_count != 0
            @header.max_frame = number
            @header.database_page_count = commit_page_count
            @header.page_size = page_bytes
            committed = checksum
          end
          number += 1
        end
        @index.map_region(region, grow: true)
        offset = region * SharedMemory::REGION_SIZE
        @index.write_bytes(offset + base, private_region[base, SharedMemory::REGION_SIZE - base])
        region += 1
      end
      committed
    end

    private def append_to_private_region(region : Bytes, base : Int32, slot : Int32, page_number : UInt32) : Nil
      key = WalIndexLayout.hash(page_number)
      while IO::ByteFormat::SystemEndian.decode(UInt16, region[HASH_TABLE_BYTE_OFFSET + key * 2, 2]) != 0
        key = (key + 1) & (HASH_SLOTS - 1)
      end
      IO::ByteFormat::SystemEndian.encode(page_number, region[base + (slot - 1) * 4, 4])
      IO::ByteFormat::SystemEndian.encode(slot.to_u16, region[HASH_TABLE_BYTE_OFFSET + key * 2, 2])
    end

    # --- Checkpoints ---------------------------------------------------------

    # sqlite3WalCheckpoint, run with no read or write transaction open: the
    # CKPT lock (busy at once when another checkpoint runs), the WRITE lock
    # for FULL, RESTART and TRUNCATE (waiting up to *busy_timeout*, falling
    # back to PASSIVE), then the copy. *database* receives the pages.
    def checkpoint(mode : CheckpointMode, database : DatabaseFile, busy_timeout : Time::Span?) : CheckpointResult
      return CheckpointResult.new(true, -1, -1) unless @index.lock_exclusive(CKPT_LOCK)
      @holds_checkpoint_lock = true
      effective_mode = mode
      @changed = false
      # One busy handler for every lock this checkpoint waits for, as C
      # passes the connection's handler to each walBusyLock.
      handler = busy_timeout && !mode.passive? ? BusyWait::Handler.new(busy_timeout) : nil
      begin
        unless mode.passive?
          if BusyWait.attempt(handler) { @index.lock_exclusive(WRITE_LOCK) }
            @writing = true
          else
            effective_mode = CheckpointMode::Passive
            handler = nil
          end
        end
        return CheckpointResult.new(true, -1, -1) if read_index_header.busy?
        completed = copy_frames(effective_mode, database, handler)
        CheckpointResult.new(!completed || effective_mode != mode, @header.max_frame.to_i32, backfilled_frames.to_i32)
      ensure
        # A checkpoint that read a newer header leaves this connection's
        # snapshot empty, so its next read starts over.
        @header = WalIndexHeader.new if @changed
        end_write
        @index.unlock(CKPT_LOCK)
        @holds_checkpoint_lock = false
      end
    end

    # walCheckpoint. Copies, for each page, its latest frame among those
    # after the backfilled ones and no later than the oldest read mark in
    # use, so no reader sees a page change under it. Returns false when a
    # FULL, RESTART or TRUNCATE checkpoint could not finish.
    private def copy_frames(mode : CheckpointMode, database : DatabaseFile, handler : BusyWait::Handler?) : Bool
      page_size = @header.page_size
      if backfilled_frames < @header.max_frame
        safe_frame = @header.max_frame
        max_page = @header.database_page_count
        1.upto(READER_COUNT - 1) do |index|
          mark = read_mark(index)
          next unless safe_frame > mark
          if lock_waiting(WalIndexLayout.read_lock(index), 1, handler)
            set_read_mark(index, index == 1 ? safe_frame : READ_MARK_NOT_USED)
            @index.unlock(WalIndexLayout.read_lock(index))
          else
            safe_frame = mark
            handler = nil
          end
        end
        backfilled = backfilled_frames
        if backfilled < safe_frame && lock_waiting(WalIndexLayout.read_lock(0), 1, handler)
          begin
            @index.write_u32(BACKFILL_ATTEMPTED, safe_frame)
            @log.sync(@checkpoint_sync_mode) unless @synchronous.off?
            needed = max_page.to_i64 * page_size
            current = database.size
            if current < needed && current + 65_536 + @header.max_frame.to_i64 * page_size < needed
              raise CorruptDatabase.new("the WAL names #{max_page} pages, more than the database and WAL hold")
            end
            latest = {} of UInt32 => UInt32
            frame = backfilled + 1
            while frame <= safe_frame
              frame_page = page_of_frame(frame)
              latest[frame_page] = frame if frame_page <= max_page
              frame += 1
            end
            buffer = Bytes.new(page_size)
            latest.keys.sort!.each do |page_number|
              offset = frame_offset(latest[page_number], page_size) + FRAME_HEADER_SIZE
              raise CorruptDatabase.new("WAL frame #{latest[page_number]} is truncated") if @log.read_at(offset, buffer) < page_size
              database.write_at((page_number.to_i64 - 1) * page_size, buffer)
            end
            if safe_frame == live_header.max_frame
              database.truncate(max_page.to_i64 * page_size)
              database.sync(@checkpoint_sync_mode) unless @synchronous.off?
            end
            @index.write_u32(BACKFILL_OFFSET, safe_frame)
          ensure
            @index.unlock(WalIndexLayout.read_lock(0))
          end
        end
      end
      return true if mode.passive?
      return false if backfilled_frames < @header.max_frame
      return true unless mode.restart? || mode.truncate?
      salt = Random.rand(UInt32)
      return false unless lock_waiting(WalIndexLayout.read_lock(1), READER_COUNT - 1, handler)
      begin
        if mode.truncate?
          restart_header(salt)
          @log.truncate(0)
        end
      ensure
        @index.unlock(WalIndexLayout.read_lock(1), READER_COUNT - 1)
      end
      true
    end

    # walBusyLock: an exclusive lock, waiting while *handler* allows (nil:
    # not at all).
    private def lock_waiting(slot : Int32, count : Int32, handler : BusyWait::Handler?) : Bool
      BusyWait.attempt(handler) { @index.lock_exclusive(slot, count) }
    end

    # --- Closing ---------------------------------------------------------------

    # sqlite3WalClose: when *exclusive* (no other connection has the
    # database open), checkpoints everything and removes the `-wal` and
    # `-shm` files.
    def close(database : DatabaseFile, exclusive : Bool) : Nil
      end_write
      end_read
      delete = false
      if exclusive
        result = checkpoint(CheckpointMode::Passive, database, nil)
        delete = !result.busy && backfilled_frames_after_close_check
      end
      @index.close(delete)
      @log.close
      @file_system.delete(@log_path) if delete
    end

    # A passive checkpoint run alone copies every frame; the files go only
    # when it did.
    private def backfilled_frames_after_close_check : Bool
      @index.map_region(0, grow: false) && backfilled_frames == live_header.max_frame
    end

    # --- Format helpers --------------------------------------------------------

    private def frame_offset(frame : UInt32, page_size : Int32) : Int64
      HEADER_SIZE.to_i64 + (frame.to_i64 - 1) * (FRAME_HEADER_SIZE + page_size)
    end

    # The WAL checksum (walformat.html §1, "Checksum Algorithm") over
    # *data*, a multiple of 8 bytes: 32-bit words in little-endian order,
    # or big-endian when the WAL's magic number says so.
    def self.checksum(data : Bytes, seed : {UInt32, UInt32}, big_endian : Bool = false) : {UInt32, UInt32}
      sum0, sum1 = seed
      words = data.to_unsafe.as(UInt32*)
      count = data.size // 4
      index = 0
      if big_endian
        while index + 1 < count
          sum0 = sum0 &+ words[index].byte_swap &+ sum1
          sum1 = sum1 &+ words[index + 1].byte_swap &+ sum0
          index += 2
        end
      else
        pairs = data.to_unsafe.as(UInt64*)
        pair_count = count // 2
        return checksum_of_lanes(pairs, pair_count, seed) if pair_count >= LANE_MINIMUM_PAIRS
        return checksum_of_pairs(pairs, pair_count, seed)
      end
      {sum0, sum1}
    end

    # Pages this long or longer take the four-lane checksum.
    LANE_MINIMUM_PAIRS = 64

    # One step of the checksum takes a pair of words (w0, w1) and the sums
    # (s0, s1) to (s0 + s1 + w0, s0 + 2·s1 + w0 + w1): a fixed matrix
    # [[1, 1], [1, 2]] times the sums, plus the words. So the sums after
    # a run of pairs are that matrix's power times the starting sums, plus
    # what the run gives from sums of zero, all modulo 2^32. The page is
    # cut into four runs whose chains of additions are independent, so the
    # processor adds them side by side; each run's part is moved past the
    # runs after it by a power of the matrix. The result is the serial
    # checksum's, bit for bit.
    private def self.checksum_of_lanes(pairs : UInt64*, pair_count : Int32, seed : {UInt32, UInt32}) : {UInt32, UInt32}
      run_length = pair_count // 4
      first_run = pairs
      second_run = pairs + run_length
      third_run = pairs + 2 * run_length
      fourth_run = pairs + 3 * run_length
      first0 = first1 = second0 = second1 = third0 = third1 = fourth0 = fourth1 = 0_u32
      index = 0
      while index < run_length
        first_pair = first_run[index]
        second_pair = second_run[index]
        third_pair = third_run[index]
        fourth_pair = fourth_run[index]
        first0 = first0 &+ first_pair.to_u32! &+ first1
        second0 = second0 &+ second_pair.to_u32! &+ second1
        third0 = third0 &+ third_pair.to_u32! &+ third1
        fourth0 = fourth0 &+ fourth_pair.to_u32! &+ fourth1
        first1 = first1 &+ (first_pair >> 32).to_u32! &+ first0
        second1 = second1 &+ (second_pair >> 32).to_u32! &+ second0
        third1 = third1 &+ (third_pair >> 32).to_u32! &+ third0
        fourth1 = fourth1 &+ (fourth_pair >> 32).to_u32! &+ fourth0
        index += 1
      end
      one_run = ChecksumStep.power(run_length)
      two_runs = one_run * one_run
      three_runs = two_runs * one_run
      sum0, sum1 = (two_runs * two_runs).apply(seed[0], seed[1])
      part0, part1 = three_runs.apply(first0, first1)
      sum0 &+= part0
      sum1 &+= part1
      part0, part1 = two_runs.apply(second0, second1)
      sum0 &+= part0
      sum1 &+= part1
      part0, part1 = one_run.apply(third0, third1)
      sum0 &+= part0 &+ fourth0
      sum1 &+= part1 &+ fourth1
      checksum_of_pairs(pairs + 4 * run_length, pair_count - 4 * run_length, {sum0, sum1})
    end

    # The checksum pair by pair; each pair of words is one 64-bit load (the
    # low half is the first word on a little-endian host), four pairs per
    # turn of the loop.
    private def self.checksum_of_pairs(pairs : UInt64*, pair_count : Int32, seed : {UInt32, UInt32}) : {UInt32, UInt32}
      sum0, sum1 = seed
      pair = 0
      while pair + 4 <= pair_count
        first = pairs[pair]
        second = pairs[pair + 1]
        third = pairs[pair + 2]
        fourth = pairs[pair + 3]
        sum0 = sum0 &+ first.to_u32! &+ sum1
        sum1 = sum1 &+ (first >> 32).to_u32! &+ sum0
        sum0 = sum0 &+ second.to_u32! &+ sum1
        sum1 = sum1 &+ (second >> 32).to_u32! &+ sum0
        sum0 = sum0 &+ third.to_u32! &+ sum1
        sum1 = sum1 &+ (third >> 32).to_u32! &+ sum0
        sum0 = sum0 &+ fourth.to_u32! &+ sum1
        sum1 = sum1 &+ (fourth >> 32).to_u32! &+ sum0
        pair += 4
      end
      while pair < pair_count
        word_pair = pairs[pair]
        sum0 = sum0 &+ word_pair.to_u32! &+ sum1
        sum1 = sum1 &+ (word_pair >> 32).to_u32! &+ sum0
        pair += 1
      end
      {sum0, sum1}
    end

    # A power of the checksum step's matrix [[1, 1], [1, 2]], modulo 2^32.
    struct ChecksumStep
      getter top_left : UInt32
      getter top_right : UInt32
      getter bottom_left : UInt32
      getter bottom_right : UInt32

      def initialize(@top_left : UInt32, @top_right : UInt32, @bottom_left : UInt32, @bottom_right : UInt32)
      end

      # The matrix to the power *exponent*, by repeated squaring.
      def self.power(exponent : Int32) : ChecksumStep
        result = new(1_u32, 0_u32, 0_u32, 1_u32)
        base = new(1_u32, 1_u32, 1_u32, 2_u32)
        while exponent > 0
          result = result * base if exponent.odd?
          base = base * base
          exponent >>= 1
        end
        result
      end

      def *(other : ChecksumStep) : ChecksumStep
        ChecksumStep.new(
          @top_left &* other.top_left &+ @top_right &* other.bottom_left,
          @top_left &* other.top_right &+ @top_right &* other.bottom_right,
          @bottom_left &* other.top_left &+ @bottom_right &* other.bottom_left,
          @bottom_left &* other.top_right &+ @bottom_right &* other.bottom_right)
      end

      # The matrix times the sums (*sum0*, *sum1*).
      def apply(sum0 : UInt32, sum1 : UInt32) : {UInt32, UInt32}
        {@top_left &* sum0 &+ @top_right &* sum1, @bottom_left &* sum0 &+ @bottom_right &* sum1}
      end
    end

    private def put_big_endian(bytes : Bytes, offset : Int32, value : UInt32) : Nil
      bytes[offset] = (value >> 24).to_u8!
      bytes[offset + 1] = (value >> 16).to_u8!
      bytes[offset + 2] = (value >> 8).to_u8!
      bytes[offset + 3] = value.to_u8!
    end

    private def get_big_endian(bytes : Bytes, offset : Int32) : UInt32
      (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) | (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3]
    end
  end
end
