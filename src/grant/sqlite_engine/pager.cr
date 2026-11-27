module Grant::SQLiteEngine
  # One savepoint level of a write transaction (see `Pager#open_savepoint`).
  class SavepointLevel
    getter images = {} of UInt32 => Bytes?
    getter page_count : UInt32
    # False for an autocommit statement C runs without a statement
    # journal: the level keeps no page images of its own (pages it changes
    # are imaged for the level around it, if any). A failure rolls the
    # whole transaction back, so nothing reads the images.
    property? keeps_images = true

    def initialize(@page_count : UInt32)
    end

    # Makes a released level a new one, keeping its emptied image table.
    def reopen(page_count : UInt32) : self
      @images.clear
      @page_count = page_count
      @keeps_images = true
      self
    end
  end

  # Reads pages by number from the database file, overlaid with the committed
  # frames of the WAL when one exists, and caches recently read pages.
  #
  # Opened read-write (`Pager.open_read_write`), it also writes: pages
  # changed inside a write transaction stay in memory (dirty) until commit,
  # which journals their original images in a rollback journal, writes them
  # and deletes the journal (atomiccommit.html). Pages come from the
  # freelist before the file grows, and the lock-byte page is never used.
  class Pager
    # fileformat2.html §1.3: the lock-byte page holds the byte range at
    # offset 2^30 and is never used for content.
    PENDING_BYTE_OFFSET = 1_073_741_824_i64

    # Pages kept in memory before the cache is emptied and refilled.
    DEFAULT_CACHE_PAGES = 4_096

    # The SQLite release whose file format the writer follows; written at
    # header offset 96 on every commit (fileformat2.html §1.3.16).
    WRITER_VERSION_NUMBER = 3_051_000_u32

    # Header offsets (fileformat2.html §1.3).
    CHANGE_COUNTER_OFFSET    = 24
    PAGE_COUNT_OFFSET        = 28
    FREELIST_TRUNK_OFFSET    = 32
    FREELIST_COUNT_OFFSET    = 36
    SCHEMA_COOKIE_OFFSET     = 40
    VERSION_VALID_FOR_OFFSET = 92
    VERSION_NUMBER_OFFSET    = 96

    getter header : DatabaseHeader?
    getter page_size : Int32
    getter usable_size : Int32
    getter page_count : UInt32
    getter wal : WalReader?
    # Counts the times cached pages were dropped (another connection's commit,
    # a rollback); a cached schema older than this is stale.
    getter generation = 0
    # Pages changed since the pager opened (any page_for_write call).
    getter change_count = 0_u64
    # The rightmost path (root, interior pages with the child taken, leaf)
    # of the table b-tree written last; BTreeWriter checks it page by page
    # before trusting it, so it is only ever a shortcut.
    property rightmost_path_hint : {UInt32, Array({UInt32, Int32}), UInt32}? = nil

    @cache = PageTable.new

    # SQLITE_DEFAULT_WAL_AUTOCHECKPOINT: a commit that leaves at least this
    # many frames in the WAL runs a passive checkpoint.
    DEFAULT_WAL_AUTOCHECKPOINT = 1_000

    # The page cache defaults of the C library each platform ships, so a
    # transaction spills changed pages where that library does.
    {% if flag?(:darwin) %}
      # Apple's /usr/lib/libsqlite3.dylib (SQLite 3.51.0 on macOS 26): its
      # PRAGMA compile_options lists DEFAULT_CACHE_SIZE=2000, and PRAGMA
      # cache_size reads 2000 (pages) on a new connection.
      DEFAULT_CACHE_SIZE = 2_000_i64
      # Apple's build: PRAGMA cache_spill reads 20000 on a new connection at
      # page sizes 1,024, 4,096 and 65,536 alike, so its szSpill starts at
      # 20,000 pages (no compile option names it).
      DEFAULT_CACHE_SPILL_PAGES = 20_000_i64
    {% else %}
      # SQLITE_DEFAULT_CACHE_SIZE in upstream sqliteLimit.h (Ubuntu 24.04's
      # libsqlite3 3.45.1 too): 2,000 KiB of pages.
      DEFAULT_CACHE_SIZE = -2_000_i64
      # sqlite3PcacheOpen in upstream pcache.c sets szSpill = 1, so the cache
      # spills as soon as pcache1 refuses a page.
      DEFAULT_CACHE_SPILL_PAGES = 1_i64
    {% end %}
    # PRAGMA synchronous: FULL (sync at every commit) by default, as C's
    # default build.
    getter synchronous : Synchronous = Synchronous::Full
    # PRAGMA fullfsync: every sync is a `SyncMode::Full` one.
    getter? fullfsync = false
    # PRAGMA checkpoint_fullfsync: the syncs of a checkpoint are
    # `SyncMode::Full` ones. fullfsync turns them on as well.
    getter? checkpoint_fullfsync = false
    # PRAGMA wal_autocheckpoint; 0 or less turns it off.
    property wal_autocheckpoint : Int32 = DEFAULT_WAL_AUTOCHECKPOINT
    # How long a checkpoint or `Database#transaction` waits for another
    # connection's lock (sqlite3_busy_timeout).
    property busy_timeout : Time::Span = Time::Span.zero

    # The WAL in use when the database is in WAL mode.
    @wal_log : WriteAheadLog? = nil
    @checkpoint_due = false
    # Set while leaving WAL mode, when the header still says WAL.
    @leaving_wal = false

    # Read-write state.
    @file : DatabaseFile? = nil
    @file_system : FileSystem? = nil
    @path = ""
    @new_page_size = Limits::DEFAULT_PAGE_SIZE
    @new_text_encoding = TextEncoding::UTF8
    @dirty = PageTable.new
    @journal_images = PageTable.new
    @original_page_count = 0_u32
    @in_write_transaction = false
    @read_depth = 0
    # The open savepoint levels, innermost last: each keeps the image of
    # every page it saw changed first (nil for a page that was not dirty, or
    # did not exist, when the level opened) and the page count it started
    # with. The statement journal is the innermost level.
    @list_of_savepoint_levels = [] of SavepointLevel

    # PRAGMA cache_size: pages when positive, KiB when negative. In a
    # rollback-journal transaction it sets when changed pages spill to the
    # database file (`#spill_threshold`).
    getter cache_size : Int64 = DEFAULT_CACHE_SIZE
    # PRAGMA cache_spill: pcache's szSpill, the pages the cache may hold
    # before a fetch spills (`#cache_spill_size=`), and whether spills happen
    # at all (SQLITE_CacheSpill, PAGER_CACHESPILL).
    getter cache_spill_pages : Int64 = DEFAULT_CACHE_SPILL_PAGES
    property? cache_spill_allowed = true
    # The busy handler of the statement running now (C keeps one per
    # connection, its count reset as each statement starts): a cache spill
    # and the COMMIT of an autocommit statement wait on it, so the waits of
    # one statement together last no longer than busy_timeout.
    getter busy_handler = BusyWait::Handler.new(Time::Span.zero)
    # Cache spill state of a rollback-journal transaction (pagerStress):
    # the pages a spill took from the changed pages, which C's cache then
    # counts clean, each holding the bytes COMMIT writes (their journal
    # records are synced; see `#spill_pages`); the changed pages
    # journaled since the journal was last synced, which wait for the next
    # sync (PGHDR_NEED_SYNC); whether the journal has been synced in this
    # transaction (PAGER_WRITER_DBMOD: before then every changed page waits
    # for a sync); whether a spill's pages wait for their write; and the
    # clean pages read since the current change began, which stand for the
    # pages C's cursors hold.
    @spilled = PageTable.new
    @unsynced = PageTable.new
    @journal_synced = false
    @spill_due = false
    @held_pages = 0
    # Set once COMMIT starts writing database pages: a rollback after that
    # (a failed write or sync) plays the journal back.
    @database_file_changed = false

    # A database with no pages (a zero-length file and no WAL) is an empty
    # database, as in SQLite.
    #
    # *log_pending* is true when the read-write open will read a WAL next:
    # the size check on page 1 waits for the WAL's snapshot.
    #
    # *unread* opens without reading the file, as an empty database; the
    # first locked read finds the file changed and loads it.
    def initialize(@main : ByteSource, wal_source : ByteSource? = nil, @cache_pages : Int32 = DEFAULT_CACHE_PAGES,
                   @log_pending : Bool = false, unread : Bool = false)
      wal = wal_source ? WalReader.read?(wal_source) : nil
      wal_source.close if wal_source && wal.nil?
      @wal = wal
      @page_size = 0
      @usable_size = 0
      @page_count = 0_u32
      @header = nil
      load_first_page unless unread
    end

    # Opens *path* for reading and writing through *file_system*, creating
    # an empty database when the file does not exist. A hot journal left by
    # a crash is rolled back first. A database whose header says WAL (or
    # that has a `-wal` file) opens in WAL mode and holds a SHARED lock on
    # the database file until it closes, as C does. *page_size* and
    # *text_encoding* apply only when the first transaction creates the
    # database. *cache_pages* bounds the clean pages kept in memory; nil
    # sizes the cache as SQLite's default of 2,000 KiB.
    #
    # sqlite3_open_v2 takes no lock and reads nothing, so an open never
    # fails because another connection holds the file. While one holds it
    # exclusively (a rollback-journal commit, BEGIN EXCLUSIVE, the last WAL
    # connection checkpointing as it closes) the open reads nothing either:
    # the first statement loads the database under its own lock, waiting
    # as busy_timeout says.
    def self.open_read_write(file_system : FileSystem, path : String, cache_pages : Int32? = nil,
                             page_size : Int32 = Limits::DEFAULT_PAGE_SIZE,
                             text_encoding : TextEncoding = TextEncoding::UTF8,
                             synchronous : Synchronous = Synchronous::Full,
                             wal_autocheckpoint : Int32 = DEFAULT_WAL_AUTOCHECKPOINT) : Pager
      valid_size = page_size >= Limits::MIN_PAGE_SIZE && page_size <= Limits::MAX_PAGE_SIZE && (page_size & (page_size - 1)) == 0
      raise ArgumentError.new("page_size #{page_size} is not a power of two from 512 to 65536") unless valid_size
      file = file_system.open(path)
      begin
        unless file.lock(LockLevel::Shared)
          unread = new(file, nil, unread: true)
          unread.attach_writer(file_system, path, file, page_size, text_encoding, cache_pages)
          unread.synchronous = synchronous
          unread.wal_autocheckpoint = wal_autocheckpoint
          return unread
        end
        pager = begin
          # No PRAGMA has been read yet, so a journal found here is rolled
          # back with the strongest sync: a C connection that sets
          # fullfsync before its first read rolls back the same way.
          roll_back_hot_journal(file_system, path, file, SyncMode::Full)
          # pagerOpenWalIfPresent: a WAL beside an empty database is stale.
          wal_path = WriteAheadLog.path_for(path)
          file_system.delete(wal_path) if file.size == 0 && file_system.exists?(wal_path)
          opened = new(file, nil, log_pending: file_system.exists?(wal_path))
          opened.attach_writer(file_system, path, file, page_size, text_encoding, cache_pages)
          opened.synchronous = synchronous
          opened.wal_autocheckpoint = wal_autocheckpoint
          if opened.wal_wanted?
            opened.open_log
            opened.load_log_snapshot
          end
          opened
        rescue error
          file.unlock(LockLevel::None)
          raise error
        end
        # WAL mode holds SHARED on the database file until the connection closes.
        file.unlock(LockLevel::None) unless pager.wal_mode?
        pager
      rescue error
        file.close
        raise error
      end
    end

    protected def attach_writer(@file_system : FileSystem, @path : String, @file : DatabaseFile, @new_page_size : Int32,
                                @new_text_encoding : TextEncoding, cache_pages : Int32?) : Nil
      page_size = @page_size > 0 ? @page_size : @new_page_size
      @cache_pages = cache_pages || Math.max(16, Limits::DEFAULT_CACHE_KIBIBYTES * 1024 // page_size)
      @cache_size = cache_pages.to_i64 if cache_pages
    end

    # PRAGMA cache_size N.
    def cache_size=(@cache_size : Int64) : Int64
      @cache_size
    end

    # PRAGMA cache_spill N (sqlite3PcacheSetSpillsize): N pages, or with a
    # negative N that many KiB of pages at the current page size; 0 keeps
    # the size there is.
    def cache_spill_size=(size : Int64) : Int64
      unless size == 0
        @cache_spill_pages = size < 0 ? Pager.cache_page_count(size, current_page_size) : size
      end
      size
    end

    # PRAGMA cache_spill as C reads it (sqlite3BtreeSetSpillSize(pBt, 0)):
    # the larger of the cache size and szSpill in pages, or 0 while spills
    # are off.
    def cache_spill_report : Int64
      return 0_i64 unless @cache_spill_allowed
      Math.max(cache_page_limit, @cache_spill_pages)
    end

    # ROUND8(sizeof(MemPage)) of a 64-bit C SQLite 3.51.0: the bytes C adds
    # to each cached page when it turns a cache_size in KiB into pages
    # (numberOfCachePages).
    C_PAGE_EXTRA = 136

    # numberOfCachePages: *size* pages when positive, else -*size* KiB of
    # pages of *page_size* bytes plus C's per-page extra, at most 10^9.
    def self.cache_page_count(size : Int64, page_size : Int32) : Int64
      return size if size >= 0
      Math.min(-1024_i64 * size // (page_size + C_PAGE_EXTRA), 1_000_000_000_i64)
    end

    # pcache1's nMax: the pages the cache keeps at the current cache_size.
    private def cache_page_limit : Int64
      Pager.cache_page_count(@cache_size, current_page_size)
    end

    private def current_page_size : Int32
      @page_size > 0 ? @page_size : @new_page_size
    end

    # pcache1's n90pct: once this many pages are pinned (changed and not
    # yet written, or held by a cursor), the next page C fetches into its
    # cache asks for a spill (sqlite3PcacheFetch, pcache1FetchStage2).
    def spill_threshold : Int64
      cache_page_limit * 9 // 10
    end

    # Starts the busy handler of a new statement with the current
    # busy_timeout (C sets db->busyHandler.nBusy to 0 as sqlite3VdbeExec
    # starts).
    def start_busy_handler : Nil
      @busy_handler.restart(@busy_timeout)
    end

    def synchronous=(level : Synchronous) : Synchronous
      @wal_log.try(&.synchronous=(level))
      @synchronous = level
    end

    def fullfsync=(on : Bool) : Bool
      @fullfsync = on
      share_sync_modes
      on
    end

    def checkpoint_fullfsync=(on : Bool) : Bool
      @checkpoint_fullfsync = on
      share_sync_modes
      on
    end

    # pPager->syncFlags (sqlite3PagerSetFlags): how the database file, the
    # rollback journal and a WAL commit are synced.
    def sync_mode : SyncMode
      @fullfsync ? SyncMode::Full : SyncMode::Normal
    end

    # The checkpoint half of pPager->walSyncFlags: how a checkpoint syncs
    # the WAL and the database file, and how a new WAL header is synced.
    def checkpoint_sync_mode : SyncMode
      @fullfsync || @checkpoint_fullfsync ? SyncMode::Full : SyncMode::Normal
    end

    private def share_sync_modes : Nil
      log = @wal_log
      return unless log
      log.sync_mode = sync_mode
      log.checkpoint_sync_mode = checkpoint_sync_mode
    end

    # True in WAL mode (journal_mode=WAL).
    def wal_mode? : Bool
      !@wal_log.nil?
    end

    # The WAL in use, for checks and reports; nil outside WAL mode.
    def write_ahead_log : WriteAheadLog?
      @wal_log
    end

    # lockBtree: a header whose read version is 2 asks for WAL mode, and
    # so does a `-wal` file left beside the database.
    protected def wal_wanted? : Bool
      return false if @leaving_wal || @path.empty? || writer_file_system.is_a?(MemoryFileSystem)
      return true if @header.try(&.read_format_version) == 2
      writer_file_system.exists?(WriteAheadLog.path_for(@path))
    end

    # Starts using the WAL.
    protected def open_log : Nil
      @log_pending = false
      @wal_log = WriteAheadLog.new(writer_file_system, @path, @synchronous)
      share_sync_modes
    end

    # Loads the WAL snapshot once at open, so the header and page count
    # describe the database as the WAL has it. While another connection
    # recovers the WAL this waits for the first locked read instead.
    protected def load_log_snapshot : Nil
      log = @wal_log
      return unless log
      begin
        reload if log.begin_read
        log.end_read
      rescue Busy
      end
    end

    def writable? : Bool
      !@file.nil?
    end

    def in_write_transaction? : Bool
      @in_write_transaction
    end

    # The lock this connection holds on the database file (`LockLevel::None`
    # for a read-only pager).
    def lock_level : LockLevel
      file = @file
      file ? file.lock_level : LockLevel::None
    end

    # The text encoding of the database, or of the database the first
    # transaction will create.
    def text_encoding : TextEncoding
      header.try(&.text_encoding) || @new_text_encoding
    end

    # Returns the page bytes. Raises `CorruptDatabase` when *page_number* is
    # 0, past the end of the database, or the lock-byte page.
    def read_page(page_number : UInt32) : Bytes
      if dirty = @dirty[page_number]?
        return dirty
      end
      if cached = @cache[page_number]?
        @held_pages &+= 1 unless page_number == 1
        return cached
      end
      check_page_number(page_number)
      spill_when_full
      @held_pages &+= 1 unless page_number == 1
      # A page a spill took holds the bytes COMMIT will write (the file
      # keeps the original until then), so it comes back from memory, as
      # from C's page cache; the fetch counts as a read all the same.
      buffer = @spilled[page_number]? || read_from_file(page_number)
      @cache.clear if @cache.size >= @cache_pages
      @cache[page_number] = buffer
      buffer
    end

    # The bytes of *page_number* as the WAL or the database file holds them.
    private def read_from_file(page_number : UInt32) : Bytes
      buffer = Bytes.new(@page_size)
      wal = @wal
      log = @wal_log
      unless (log && log.read_page(page_number, buffer)) || (wal && wal.read_page(page_number, buffer))
        offset = (page_number.to_i64 - 1) * @page_size
        read = @main.read_at(offset, buffer)
        raise CorruptDatabase.new("page is past the end of the file", page_number) if read < @page_size
      end
      buffer
    end

    # Raises unless *page_number* names a page of this database that may hold
    # content.
    def check_page_number(page_number : UInt32) : Nil
      if page_number == 0 || page_number > @page_count
        raise CorruptDatabase.new("page number #{page_number} is outside 1..#{@page_count}", page_number)
      end
      if page_number == lock_byte_page
        raise CorruptDatabase.new("the lock-byte page is used for content", page_number)
      end
    end

    # The lock-byte page's number for this page size.
    def lock_byte_page : UInt32
      return 0_u32 if @page_size == 0
      (PENDING_BYTE_OFFSET // @page_size + 1).to_u32
    end

    # Closes the files. In WAL mode the last connection to the database (the
    # one that gets its EXCLUSIVE lock) checkpoints the WAL and removes the
    # `-wal` and `-shm` files, as sqlite3WalClose does.
    def close : Nil
      rollback if @in_write_transaction
      if file = @file
        if log = @wal_log
          log.end_read
          log.close(file, exclusive: file.lock(LockLevel::Exclusive))
          @wal_log = nil
        end
        file.unlock(LockLevel::None)
      end
      @main.close
      @wal.try &.close
      @cache.clear
    end

    # --- Reading under a SHARED lock -----------------------------------

    # Takes a SHARED lock for the reads in the block (when read-write), first
    # rolling back a hot journal and dropping cached pages another
    # connection changed. Nested calls share the lock.
    def with_read_lock(& : -> T) : T forall T
      file = @file
      return yield unless file
      begin_read(file) if (@read_depth == 0 || @read_lock_yielded) && !@in_write_transaction
      @read_depth += 1
      begin
        yield
      ensure
        @read_depth -= 1
        end_read(file) if @read_depth == 0 && !@in_write_transaction
      end
    end

    # Takes (or shares) the SHARED lock for reads that span several calls,
    # such as one statement stepped a row at a time; each call is matched
    # by one `release_read_lock`. Raises `Busy` when a writer holds the
    # file exclusively.
    def acquire_read_lock : Nil
      file = @file
      return unless file
      begin_read(file) if (@read_depth == 0 || @read_lock_yielded) && !@in_write_transaction
      @read_depth += 1
    end

    # Set while the open reads hold no SHARED lock because `yield_read_lock`
    # gave it up; the next read or write takes it again.
    @read_lock_yielded = false

    # Gives up the SHARED lock the open reads hold on a rollback-journal
    # database, keeping their count, for a connection about to wait for the
    # write lock: C drops its read transaction before each call of the busy
    # handler (unlockBtreeIfUnused in sqlite3BtreeBeginTrans), so the
    # writer it waits for can take EXCLUSIVE and commit. In WAL mode a read
    # mark stops no writer, and it stays.
    def yield_read_lock : Nil
      file = @file
      return unless file && @wal_log.nil? && @read_depth > 0
      return if @in_write_transaction
      file.unlock(LockLevel::None)
      @read_lock_yielded = true
    end

    def release_read_lock : Nil
      file = @file
      return unless file && @read_depth > 0
      @read_depth -= 1
      end_read(file) if @read_depth == 0 && !@in_write_transaction
    end

    # In WAL mode a read takes a read mark on the WAL snapshot (the SHARED
    # lock on the database file is held from open to close); otherwise it
    # takes the SHARED lock. Cached pages go when another connection
    # committed. A rollback-journal database whose header says WAL after
    # another connection's commit switches to WAL mode here.
    private def begin_read(file : DatabaseFile) : Nil
      if log = @wal_log
        reload if log.begin_read
        return
      end
      unless file.lock(LockLevel::Shared)
        @read_lock_yielded = @read_depth > 0
        raise Busy.new
      end
      @read_lock_yielded = false
      begin
        reloaded = false
        if Pager.roll_back_hot_journal(writer_file_system, @path, file, @synchronous.off? ? nil : sync_mode) || changed_on_disk?(file)
          reload
          reloaded = true
        end
        if reloaded && wal_wanted?
          open_log
          log = @wal_log
          reload if log && log.begin_read
        end
      rescue error
        @wal_log.try &.close(file, exclusive: false)
        @wal_log = nil
        file.unlock(LockLevel::None)
        @read_lock_yielded = @read_depth > 0
        raise error
      end
    end

    # Ends a read: the read mark in WAL mode, then a checkpoint the last
    # commit made due; the SHARED lock otherwise.
    private def end_read(file : DatabaseFile) : Nil
      if log = @wal_log
        log.end_read
        run_due_checkpoint
      else
        file.unlock(LockLevel::None)
        @read_lock_yielded = false
      end
    end

    # The automatic checkpoint (sqlite3WalDefaultHook): passive, run once no
    # read is open; its failure is not the commit's.
    private def run_due_checkpoint : Nil
      return unless @checkpoint_due
      @checkpoint_due = false
      begin
        checkpoint(CheckpointMode::Passive)
      rescue Error
      end
    end

    # Runs a checkpoint (PRAGMA wal_checkpoint) outside a write
    # transaction; the connection's own read mark, if any, is dropped for
    # it and taken again afterward. Outside WAL mode it does nothing.
    def checkpoint(mode : CheckpointMode = CheckpointMode::Passive) : CheckpointResult
      log = @wal_log
      return CheckpointResult.new(false, -1, -1) unless log
      raise Error.new("database table is locked") if @in_write_transaction
      was_reading = log.reading?
      log.end_read
      begin
        log.checkpoint(mode, writer_file, mode.passive? ? nil : @busy_timeout)
      ensure
        reload if was_reading && log.begin_read
      end
    end

    # PRAGMA journal_mode=WAL: writes 2 into header bytes 18 and 19 in a
    # rollback-journal transaction (sqlite3BtreeSetVersion), creating the
    # database when it is empty, then uses the WAL. Raises `Busy` when
    # another connection keeps the write from committing.
    def enter_wal_mode : Nil
      return if wal_mode?
      if @in_write_transaction || @read_depth > 1
        raise Error.new("cannot change into wal mode from within a transaction")
      end
      set_file_format_version(2_u8)
      # Another connection turned the database to WAL while this one
      # waited: the read that found it out already uses the WAL.
      return if wal_mode?
      # WAL mode holds SHARED on the database file until the connection closes.
      raise Busy.new unless BusyWait.attempt(@busy_timeout) { writer_file.lock(LockLevel::Shared) }
      @read_lock_yielded = false
      open_log
      log = @wal_log
      return unless log && @read_depth > 0
      # Several connections starting the WAL at once take turns building
      # its index (SQLITE_BUSY_RECOVERY goes through the busy handler).
      began = BusyWait.attempt(@busy_timeout) do
        reload if log.begin_read
        true
      rescue Busy
        false
      end
      raise Busy.new unless began
    end

    # PRAGMA journal_mode=DELETE from WAL mode (sqlite3PagerCloseWal): needs
    # the EXCLUSIVE lock, so no other connection may have the database
    # open; checkpoints and removes the WAL, then writes 1 into header bytes
    # 18 and 19. Raises `Busy` when another connection has it open.
    def leave_wal_mode : Nil
      log = @wal_log
      return unless log
      if @in_write_transaction || @read_depth > 1
        raise Error.new("cannot change out of wal mode from within a transaction")
      end
      file = writer_file
      was_reading = log.reading?
      log.end_read
      unless file.lock(LockLevel::Exclusive)
        reload if was_reading && log.begin_read
        raise Busy.new
      end
      log.close(file, exclusive: true)
      @wal_log = nil
      @leaving_wal = true
      begin
        reload
        set_file_format_version(1_u8)
      ensure
        @leaving_wal = false
        file.unlock(@read_depth > 0 ? LockLevel::Shared : LockLevel::None)
      end
    end

    # Writes *version* into header bytes 18 and 19 when they differ, in a
    # transaction of its own, waiting up to busy_timeout for other
    # connections and holding no lock between tries.
    private def set_file_format_version(version : UInt8) : Nil
      done = BusyWait.attempt(@busy_timeout) do
        begin_write
        begin
          page = read_page(1_u32)
          if page[18] != version || page[19] != version
            page = page_for_write(1_u32)
            page[18] = version
            page[19] = version
          end
          commit
          true
        rescue Busy
          rollback
          yield_read_lock
          false
        rescue error
          rollback
          raise error
        end
      rescue Busy
        yield_read_lock
        false
      end
      raise Busy.new unless done
    end

    # SQLite compares header bytes 24..39 (the change counter and the page
    # count among them) with its cached copy to tell whether another
    # connection committed.
    private def changed_on_disk?(file : DatabaseFile) : Bool
      on_disk = Bytes.new(16)
      read = file.read_at(CHANGE_COUNTER_OFFSET.to_i64, on_disk)
      return read > 0 if @page_count == 0
      return true if read < 16
      cached = @cache[1_u32]?
      return true unless cached
      cached[CHANGE_COUNTER_OFFSET, 16] != on_disk
    end

    private def reload : Nil
      @generation += 1
      @cache.clear
      @page_size = 0
      @usable_size = 0
      @page_count = 0_u32
      @header = nil
      load_first_page
    end

    # Rolls back the journal of *path* when it is hot, under an EXCLUSIVE
    # lock, syncing the database in *sync_mode* (nil: no sync), and deletes
    # it. Returns true when it rolled one back.
    protected def self.roll_back_hot_journal(file_system : FileSystem, path : String, file : DatabaseFile,
                                             sync_mode : SyncMode?) : Bool
      journal_path = RollbackJournal.path_for(path)
      return false unless RollbackJournal.hot?(file_system, journal_path, file)
      held = file.lock_level
      raise Busy.new("database is locked (a hot journal needs an exclusive lock)") unless file.lock(LockLevel::Exclusive)
      begin
        journal = file_system.open(journal_path)
        begin
          RollbackJournal.play_back(journal, file, sync_mode)
        ensure
          journal.close
        end
        file_system.delete(journal_path)
      ensure
        file.unlock(held)
      end
      true
    end

    # --- Write transactions --------------------------------------------

    # Starts a write transaction: SHARED then RESERVED locks, so other
    # connections may still read but not write; in WAL mode, the WAL's
    # WRITE lock. Raises `Busy` when another connection is writing and
    # `UnsupportedSQL` for an auto-vacuum database.
    #
    # In WAL mode, a connection whose snapshot is older than the last
    # commit moves to the newest snapshot when *refresh_snapshot* is set
    # (nothing it read is kept), and otherwise raises `BusySnapshot`.
    #
    # *exclusive* (BEGIN EXCLUSIVE) also takes the EXCLUSIVE lock of a
    # rollback-journal database, so no other connection reads until the
    # transaction ends; in WAL mode it changes nothing, as in C.
    def begin_write(refresh_snapshot : Bool = true, exclusive : Bool = false) : Nil
      file = @file
      raise ReadOnlyDatabase.new unless file
      raise Error.new("a write transaction is already open") if @in_write_transaction
      begin_read(file) if @read_depth == 0 || @read_lock_yielded
      if log = @wal_log
        begin
          reload if log.begin_write(refresh_snapshot)
        rescue error
          end_read(file) if @read_depth == 0
          raise error
        end
        check_writable_header { log.end_write; end_read(file) if @read_depth == 0 }
        @in_write_transaction = true
        @original_page_count = @page_count
        create_first_page if @page_count == 0
        return
      end
      unless file.lock(LockLevel::Reserved)
        file.unlock(LockLevel::None) if @read_depth == 0
        raise Busy.new
      end
      if exclusive && !file.lock(LockLevel::Exclusive)
        file.unlock(@read_depth > 0 ? LockLevel::Shared : LockLevel::None)
        raise Busy.new
      end
      check_writable_header { file.unlock(LockLevel::None) if @read_depth == 0 }
      # A journal left behind that was not hot (empty, or zeroed) is stale:
      # the commit's `FileSystem#create_journal` cuts it to nothing.
      @in_write_transaction = true
      @original_page_count = @page_count
      create_first_page if @page_count == 0
    end

    # Yields (to release the locks just taken) and raises for a header the
    # writer does not write: a newer file format, or auto-vacuum.
    private def check_writable_header(&) : Nil
      current_header = @header
      return unless current_header
      if current_header.write_format_version > 2
        yield
        raise ReadOnlyDatabase.new
      end
      if current_header.has_pointer_map_pages?
        yield
        raise UnsupportedSQL.new("writing an auto_vacuum database")
      end
    end

    # Commits the open write transaction: takes the EXCLUSIVE lock, writes
    # and syncs the journal, writes and syncs the changed pages, then
    # deletes the journal, which is the moment the transaction commits.
    # synchronous=OFF leaves the syncs out, and fullfsync makes each one a
    # `SyncMode::Full` sync. In WAL mode it appends the changed pages to
    # the WAL instead.
    def commit : Nil
      file = writer_file
      raise Error.new("no write transaction is open") unless @in_write_transaction
      if @dirty.empty? && @spilled.empty?
        end_journal
        finish_transaction(file)
        return
      end
      if log = @wal_log
        commit_to_log(log, file)
        return
      end
      # The EXCLUSIVE lock first, so a commit refused while another
      # connection reads can be tried again unchanged.
      raise Busy.new unless file.lock(LockLevel::Exclusive)
      page_one = page_for_write(1_u32)
      counter = get_u32(page_one, CHANGE_COUNTER_OFFSET) &+ 1
      put_u32(page_one, CHANGE_COUNTER_OFFSET, counter)
      put_u32(page_one, PAGE_COUNT_OFFSET, @page_count)
      put_u32(page_one, VERSION_VALID_FOR_OFFSET, counter)
      put_u32(page_one, VERSION_NUMBER_OFFSET, WRITER_VERSION_NUMBER)
      # The journal's last segment is synced (syncJournal), then every
      # changed page goes out once, in page order: the changed pages and
      # the pages spills took (a page changed again after its spill is
      # among the changed pages, with its newest bytes), in a list kept
      # from one commit to the next (as `commit_to_log` keeps its own). A
      # spilled page past the end a savepoint rollback left is not written.
      start_journal unless @journal_writer.journal
      @journal_writer.sync_segment(new_segment: false)
      list_of_pages = @commit_pages
      list_of_pages.clear
      @dirty.each { |page_number, buffer| list_of_pages << {page_number, buffer} }
      @spilled.each do |page_number, buffer|
        list_of_pages << {page_number, buffer} unless page_number > @page_count || @dirty.has_key?(page_number)
      end
      list_of_pages.sort! { |left, right| left[0] <=> right[0] }
      @database_file_changed = true
      list_of_pages.each do |page_number, buffer|
        file.write_at((page_number.to_i64 - 1) * @page_size, buffer)
      end
      file.sync(sync_mode) unless @synchronous.off?
      end_journal
      list_of_pages.clear
      # The changed pages stay in the clean cache; a page a spill took
      # stays only where a read cached it, as when the spill wrote it, so
      # the next transaction fetches (and spills) where C's does.
      @dirty.each { |page_number, buffer| @cache[page_number] = buffer }
      @header = DatabaseHeader.parse(page_one)
      finish_transaction(file)
    end

    # Ends the open write transaction without writing anything.
    def rollback : Nil
      file = writer_file
      return unless @in_write_transaction
      # Page 1 as the transaction left it, changed or taken by a spill.
      written_first_page = @dirty[1_u32]? || @spilled[1_u32]?
      written_cookie = written_first_page ? get_u32(written_first_page, SCHEMA_COOKIE_OFFSET) : nil
      @rightmost_path_hint = nil
      # Spills write no database page, so the file holds every original
      # unless a COMMIT failed partway through its writes.
      play_back_journal(file) if @database_file_changed
      end_journal
      @dirty.each_key { |page_number| @cache.delete(page_number) }
      @spilled.each_key { |page_number| @cache.delete(page_number) }
      @spilled.clear
      # Page 1 below comes from the snapshot, not from the rolled-back pages.
      @dirty.clear
      @page_count = @original_page_count
      if @page_count == 0
        @page_size = 0
        @usable_size = 0
        @header = nil
        @cache.clear
        @generation += 1
      else
        restored_first_page = read_page_after_rollback(1_u32)
        @header = DatabaseHeader.parse(restored_first_page)
        # The schema caches go only when the transaction changed the schema
        # (C resets the schema on rollback only after DBFLAG_SchemaChange);
        # rolled-back pages leave the cache above either way.
        @generation += 1 if written_cookie && written_cookie != get_u32(restored_first_page, SCHEMA_COOKIE_OFFSET)
      end
      finish_transaction(file)
    end

    # pagerWalFrames: page 1 is written only when the transaction changed
    # it or the database grew, and then carries the next change counter
    # (pager_write_changecounter); the changed pages within the database's
    # size become frames, the last one the commit frame.
    private def commit_to_log(log : WriteAheadLog, file : DatabaseFile) : Nil
      if @dirty.has_key?(1_u32) || get_u32(read_page(1_u32), PAGE_COUNT_OFFSET) != @page_count
        page_one = page_for_write(1_u32)
        counter = get_u32(page_one, CHANGE_COUNTER_OFFSET) &+ 1
        put_u32(page_one, CHANGE_COUNTER_OFFSET, counter)
        put_u32(page_one, PAGE_COUNT_OFFSET, @page_count)
        put_u32(page_one, VERSION_VALID_FOR_OFFSET, counter)
        put_u32(page_one, VERSION_NUMBER_OFFSET, WRITER_VERSION_NUMBER)
      end
      # A list kept for the next commit: the log writes the frames before
      # it returns.
      list_of_pages = @commit_pages
      list_of_pages.clear
      @dirty.each { |page_number, buffer| list_of_pages << {page_number, buffer} if page_number <= @page_count }
      list_of_pages.sort! { |left, right| left[0] <=> right[0] }
      log.commit(list_of_pages, @page_count, @page_size)
      list_of_pages.clear
      @dirty.each { |page_number, buffer| @cache[page_number] = buffer }
      @header = DatabaseHeader.parse(read_page(1_u32))
      autocheckpoint = @wal_autocheckpoint
      @checkpoint_due = true if autocheckpoint > 0 && log.frame_count >= autocheckpoint
      finish_transaction(file)
    end

    @commit_pages = [] of {UInt32, Bytes}
    @commit_images = [] of {UInt32, Bytes}
    @journal_writer = RollbackJournal::Writer.new

    private def finish_transaction(file : DatabaseFile) : Nil
      @dirty.clear
      # The journal's page images are written (or the transaction rolled
      # back); the next transaction's images reuse them.
      @journal_images.each_value { |image| recycle_image(image) }
      @journal_images.clear
      @spilled.clear
      @unsynced.clear
      @journal_synced = false
      @spill_due = false
      @database_file_changed = false
      @list_of_savepoint_levels.clear
      @in_write_transaction = false
      if log = @wal_log
        log.end_write
        end_read(file) if @read_depth == 0
      else
        file.unlock(@read_depth > 0 ? LockLevel::Shared : LockLevel::None)
      end
    end

    private def read_page_after_rollback(page_number : UInt32) : Bytes
      @cache.delete(page_number)
      read_page(page_number)
    end

    # Starts a statement inside the write transaction: a failed statement
    # puts back exactly the pages it changed (the statement journal).
    def begin_statement : Nil
      open_savepoint
    end

    def end_statement : Nil
      release_savepoint(@list_of_savepoint_levels.size) unless @list_of_savepoint_levels.empty?
    end

    def rollback_statement : Nil
      depth = @list_of_savepoint_levels.size
      return if depth == 0
      rollback_to_savepoint(depth)
      @list_of_savepoint_levels.pop
    end

    # Opens a savepoint level inside the write transaction and returns its
    # depth (1 for the outermost).
    def open_savepoint : Int32
      raise Error.new("no write transaction is open") unless @in_write_transaction
      start_change
      level = @spare_levels.pop?.try(&.reopen(@page_count)) || SavepointLevel.new(@page_count)
      @list_of_savepoint_levels << level
      @list_of_savepoint_levels.size
    end

    # The number of open savepoint levels.
    def savepoint_depth : Int32
      @list_of_savepoint_levels.size
    end

    # Stops the innermost level from imaging the pages it changes (see
    # `SavepointLevel#keeps_images?`).
    def skip_savepoint_images : Nil
      @list_of_savepoint_levels.last?.try(&.keeps_images = false)
    end

    # The level that images a page changed now: the innermost one, or the
    # one around it when the innermost keeps no images.
    private def imaging_level : SavepointLevel?
      level = @list_of_savepoint_levels.last?
      return level if level.nil? || level.keeps_images?
      @list_of_savepoint_levels.size >= 2 ? @list_of_savepoint_levels[-2] : nil
    end

    # Closes the levels from *depth* inward, keeping their changes: each
    # page image a closed level kept passes to the level around it, unless
    # that level already holds an older one.
    def release_savepoint(depth : Int32) : Nil
      while @list_of_savepoint_levels.size >= depth && !@list_of_savepoint_levels.empty?
        level = @list_of_savepoint_levels.pop
        parent = @list_of_savepoint_levels.last?
        level.images.each do |page_number, image|
          if parent && !parent.images.has_key?(page_number)
            parent.images[page_number] = image
          elsif image
            recycle_image(image)
          end
        end
        @spare_levels << level if @spare_levels.size < SPARE_LEVEL_LIMIT
      end
    end

    # Released savepoint levels, reopened for the next statement instead of
    # allocating a level (and its image table) per statement.
    @spare_levels = [] of SavepointLevel
    SPARE_LEVEL_LIMIT = 8

    # Page images savepoint levels no longer hold, kept to take the next
    # image without allocating (a savepoint per statement images every page
    # the transaction already changed, as C's sub-journal does).
    @spare_images = [] of Bytes
    SPARE_IMAGE_LIMIT = 64

    private def recycle_image(image : Bytes) : Nil
      @spare_images << image if @spare_images.size < SPARE_IMAGE_LIMIT && image.size == @page_size
    end

    private def image_of(buffer : Bytes) : Bytes
      if (spare = @spare_images.pop?) && spare.size == buffer.size
        spare.copy_from(buffer.to_unsafe, buffer.size)
        return spare
      end
      buffer.dup
    end

    # Puts every page back as it was when level *depth* opened, innermost
    # level first; level *depth* stays open, empty, and the levels inside it
    # close.
    def rollback_to_savepoint(depth : Int32) : Nil
      return if depth < 1 || depth > @list_of_savepoint_levels.size
      @generation += 1
      @rightmost_path_hint = nil
      while @list_of_savepoint_levels.size >= depth
        level = @list_of_savepoint_levels.pop
        level.images.each do |page_number, image|
          if image
            if buffer = @dirty[page_number]?
              buffer.copy_from(image.to_unsafe, image.size)
              recycle_image(image)
            else
              # A page a spill took: the image comes back as a changed
              # page, ahead of the bytes the spill took.
              @cache.delete(page_number)
              @dirty[page_number] = image
            end
          else
            @dirty.delete(page_number)
            @unsynced.delete(page_number)
            @cache.delete(page_number)
            # The page was as the transaction found it. Its journal record
            # stays (the journal holds it already); a spill took changed
            # bytes, which give way to the original, back as a changed page
            # (as C's cache counts it).
            if @spilled.delete(page_number) && (original = @journal_images[page_number]?)
              @dirty[page_number] = image_of(original)
            end
          end
        end
        @page_count = level.page_count
      end
      @list_of_savepoint_levels << SavepointLevel.new(@page_count)
      if @page_count > 0
        @header = DatabaseHeader.parse(read_page(1_u32))
      end
    end

    # The bytes of *page_number* to change in place; the page's original
    # image is kept for the journal the first time the transaction touches
    # it.
    def page_for_write(page_number : UInt32) : Bytes
      raise Error.new("no write transaction is open") unless @in_write_transaction
      @change_count &+= 1
      if buffer = @dirty[page_number]?
        if level = imaging_level
          level.images[page_number] = image_of(buffer) unless level.images.has_key?(page_number)
        end
        return buffer
      end
      spill_when_full if page_number > @page_count
      buffer = page_number <= @page_count ? read_page(page_number) : Bytes.new(@page_size)
      # A rollback journal needs each page's original, appended as the page
      # is first changed; in WAL mode a rollback reads the originals back
      # from the snapshot.
      if @wal_log.nil?
        start_journal unless @journal_writer.journal
        journal_original(page_number, buffer) if page_number <= @original_page_count && !@journal_images.has_key?(page_number)
      end
      if level = imaging_level
        # nil: the page is as the database file holds it, unless a spill
        # took it, when the level keeps the bytes themselves.
        level.images[page_number] = @spilled.has_key?(page_number) ? image_of(buffer) : nil unless level.images.has_key?(page_number)
      end
      @dirty[page_number] = buffer
      buffer
    end

    # A page for new content, zeroed: the last page of the freelist's first
    # trunk, the trunk itself when it lists none, or a new page at the end of
    # the file (past the lock-byte page).
    def allocate_page : UInt32
      page_one = page_for_write(1_u32)
      trunk = get_u32(page_one, FREELIST_TRUNK_OFFSET)
      if trunk != 0
        check_page_number(trunk)
        trunk_page = page_for_write(trunk)
        leaf_count = get_u32(trunk_page, 4)
        if leaf_count > (@usable_size // 4 - 2).to_u32
          raise CorruptDatabase.new("freelist trunk lists #{leaf_count} leaves", trunk)
        end
        if leaf_count > 0
          page_number = get_u32(trunk_page, 4 + leaf_count.to_i32 * 4)
          check_page_number(page_number)
          put_u32(trunk_page, 4, leaf_count - 1)
        else
          page_number = trunk
          put_u32(page_one, FREELIST_TRUNK_OFFSET, get_u32(trunk_page, 0))
        end
        put_u32(page_one, FREELIST_COUNT_OFFSET, get_u32(page_one, FREELIST_COUNT_OFFSET) - 1)
        buffer = page_for_write(page_number)
        buffer.fill(0_u8)
        return page_number
      end
      page_number = @page_count + 1
      page_number += 1 if page_number == lock_byte_page
      if page_number > Limits::MAX_PAGE_NUMBER
        raise LimitExceeded.new("SQLITE_MAX_PAGE_COUNT", "the database would pass #{Limits::MAX_PAGE_NUMBER} pages")
      end
      spill_when_full
      start_journal if @wal_log.nil? && @journal_writer.journal.nil?
      @page_count = page_number
      @dirty[page_number] = Bytes.new(@page_size)
      if level = @list_of_savepoint_levels.last?
        level.images[page_number] = nil
      end
      page_number
    end

    # Puts *page_number* on the freelist: as a leaf of the first trunk when
    # it has room (SQLite leaves 8 slots unused for old readers), otherwise
    # as a new first trunk.
    def free_page(page_number : UInt32) : Nil
      page_one = page_for_write(1_u32)
      put_u32(page_one, FREELIST_COUNT_OFFSET, get_u32(page_one, FREELIST_COUNT_OFFSET) + 1)
      trunk = get_u32(page_one, FREELIST_TRUNK_OFFSET)
      if trunk != 0
        trunk_page = page_for_write(trunk)
        leaf_count = get_u32(trunk_page, 4)
        if leaf_count < (@usable_size // 4 - 8).to_u32
          put_u32(trunk_page, 8 + leaf_count.to_i32 * 4, page_number)
          put_u32(trunk_page, 4, leaf_count + 1)
          return
        end
      end
      new_trunk = page_for_write(page_number)
      new_trunk.fill(0_u8)
      put_u32(new_trunk, 0, trunk)
      put_u32(page_one, FREELIST_TRUNK_OFFSET, page_number)
    end

    # A header field of the page 1 being written.
    def header_field(offset : Int32) : UInt32
      get_u32(read_page(1_u32), offset)
    end

    def set_header_field(offset : Int32, value : UInt32) : Nil
      put_u32(page_for_write(1_u32), offset, value)
    end

    # Marks the start of one change of the database: a statement, or one
    # b-tree operation. No page of an earlier change is still being edited
    # here, so the pages a spill has synced leave the changed pages now (C
    # writes only pages no cursor holds), and the pages the change holds
    # are counted afresh.
    def start_change : Nil
      @held_pages = 0
      spill_pages if @spill_due
    end

    # --- Cache spill (rollback journal) ----------------------------------

    # pagerStress, at the moment C's page cache would call it: a page is
    # about to come into the cache while pages are changed, the changed
    # pages and the pages held reach `#spill_threshold`, the cache holds
    # more than cache_spill's szSpill pages (sqlite3PcacheFetchStress; the
    # pages pinned stand for pcache1's nPage, which the clean pages C
    # keeps unpinned can raise when szSpill lies between n90pct and the
    # cache size), and PRAGMA cache_spill is on (SPILLFLAG_OFF). Pages
    # that wait for no sync (journaled in a synced segment, or added past
    # the original end after the first sync) are written without one, as
    # C spills them first. Otherwise the spill takes the EXCLUSIVE lock,
    # calling the statement's busy handler while another connection reads
    # (syncJournal's sqlite3PagerExclusiveLock, pager_wait_on_lock); still
    # refused, the spill is skipped and the pages stay in memory, as C's
    # sqlite3PcacheFetchStress ignores SQLITE_BUSY. With the lock it syncs
    # the journal's segment and starts the next one (syncJournal). The
    # pages leave the changed pages at the next `#start_change`
    # (`#spill_pages`); while they wait no new spill starts.
    private def spill_when_full : Nil
      return if @dirty.empty? || @spill_due || !@wal_log.nil? || @path == ":memory:" || !@cache_spill_allowed
      held = @held_pages + (@dirty.has_key?(1_u32) ? 0 : 1)
      pinned = @dirty.size + held
      return if pinned < spill_threshold || pinned <= @cache_spill_pages
      unless @journal_synced && @dirty.size > @unsynced.size
        return unless BusyWait.attempt(@busy_handler) { writer_file.lock(LockLevel::Exclusive) }
        @journal_writer.sync_segment(new_segment: true)
        @unsynced.clear
        @journal_synced = true
      end
      @spill_due = true
    end

    # pager_write_pagelist for a spill, as far as anyone can see it: every
    # changed page whose journal record is synced leaves the changed pages,
    # as C's cache counts it clean, and keeps its bytes in memory
    # (`#read_page` returns them) until `#commit` writes each changed page
    # once. The database file is left as it is: from the spill's EXCLUSIVE
    # lock to COMMIT no other connection reads it, and a crash leaves a hot
    # journal whose playback over the untouched pages gives the same
    # database. So results, locks, result codes and the journal's bytes are
    # C's, and a page changed again after a spill is not written twice (S5
    # piece E: database pages deferred to COMMIT, C1's I/O shape J).
    private def spill_pages : Nil
      list_of_pages = @commit_pages
      list_of_pages.clear
      @dirty.each { |page_number, buffer| list_of_pages << {page_number, buffer} unless @unsynced.has_key?(page_number) }
      list_of_pages.each do |page_number, buffer|
        @dirty.delete(page_number)
        @spilled[page_number] = buffer
      end
      list_of_pages.clear
      @spill_due = false
    end

    # Keeps *page_number*'s original bytes for the transaction and appends
    # them to the journal. The page waits for the next sync before a spill
    # writes it.
    private def journal_original(page_number : UInt32, buffer : Bytes) : Nil
      image = image_of(buffer)
      @journal_images[page_number] = image
      @journal_writer.append(page_number, image)
      @unsynced[page_number] = buffer
    end

    # pager_open_journal, at the transaction's first changed page.
    private def start_journal : Nil
      journal = writer_file_system.create_journal(RollbackJournal.path_for(@path))
      page_size = @page_size > 0 ? @page_size : @new_page_size
      @journal_writer.start(journal, page_size, @original_page_count, @synchronous, sync_mode)
    end

    # pager_end_transaction: closes and deletes the journal, which commits
    # or ends the transaction.
    private def end_journal : Nil
      journal = @journal_writer.journal
      return unless journal
      @journal_writer.finish
      journal.close
      writer_file_system.delete(RollbackJournal.path_for(@path))
    end

    # pager_playback of a transaction whose COMMIT failed after it began
    # writing the database file: the file is cut to its size before the
    # transaction (pager_truncate), the original of every journaled page
    # goes back, and the file is synced unless synchronous is OFF.
    private def play_back_journal(file : DatabaseFile) : Nil
      size = @original_page_count.to_i64 * @page_size
      file.truncate(size) if file.size > size
      list_of_images = @commit_images
      list_of_images.clear
      @journal_images.each { |page_number, image| list_of_images << {page_number, image} }
      list_of_images.sort! { |left, right| left[0] <=> right[0] }
      list_of_images.each do |page_number, image|
        file.write_at((page_number.to_i64 - 1) * @page_size, image)
      end
      list_of_images.clear
      file.sync(sync_mode) unless @synchronous.off?
    end

    # --- Internals ---------------------------------------------------------

    private def writer_file : DatabaseFile
      @file || raise ReadOnlyDatabase.new
    end

    private def writer_file_system : FileSystem
      @file_system || raise ReadOnlyDatabase.new
    end

    private def load_first_page : Nil
      wal = @wal
      first_page = read_first_page(wal)
      return unless first_page
      header = DatabaseHeader.parse(first_page)
      if wal && wal.page_size != header.page_size
        raise CorruptDatabase.new("WAL page size #{wal.page_size} differs from the database page size #{header.page_size}")
      end
      log = @wal_log
      if log && log.frame_count > 0 && log.header.page_size != header.page_size
        raise CorruptDatabase.new("WAL page size #{log.header.page_size} differs from the database page size #{header.page_size}")
      end
      @header = header
      @page_size = header.page_size
      @usable_size = header.usable_size
      @page_count = count_pages(header, wal)
      @cache[1_u32] = first_page
    end

    # Page 1 of a new database: the header and an empty sqlite_schema leaf.
    private def create_first_page : Nil
      @page_size = @new_page_size
      @usable_size = @new_page_size
      @page_count = 1_u32
      start_journal if @wal_log.nil? && @journal_writer.journal.nil?
      page = Bytes.new(@page_size)
      @dirty[1_u32] = page
      if level = @list_of_savepoint_levels.last?
        level.images[1_u32] = nil
      end
      page.copy_from(DatabaseHeader::MAGIC.to_unsafe, DatabaseHeader::MAGIC.size)
      page[16] = (@page_size == Limits::MAX_PAGE_SIZE ? 0 : @page_size >> 8).to_u8
      page[17] = (@page_size == Limits::MAX_PAGE_SIZE ? 1 : @page_size & 0xff).to_u8
      page[18] = 1_u8
      page[19] = 1_u8
      page[21] = 64_u8
      page[22] = 32_u8
      page[23] = 32_u8
      put_u32(page, PAGE_COUNT_OFFSET, 1_u32)
      put_u32(page, 44, 4_u32)
      put_u32(page, 56, @new_text_encoding.value.to_u32)
      put_u32(page, VERSION_NUMBER_OFFSET, WRITER_VERSION_NUMBER)
      PageEditor.new(page, 1_u32, @usable_size).initialize_page(PageType::LeafTable)
      @header = DatabaseHeader.parse(page)
    end

    private def read_first_page(wal : WalReader?) : Bytes?
      if log = @wal_log
        log_page_size = log.header.page_size
        if log_page_size > 0
          buffer = Bytes.new(log_page_size)
          return buffer if log.read_page(1_u32, buffer)
        end
      end
      if wal
        buffer = Bytes.new(wal.page_size)
        return buffer if wal.read_page(1_u32, buffer)
      end
      return if @main.size == 0
      prefix = Bytes.new(DatabaseHeader::SIZE)
      if @main.read_at(0, prefix) < DatabaseHeader::SIZE
        raise CorruptDatabase.new("file is shorter than the 100-byte header", 1_u32)
      end
      DatabaseHeader.check_magic(prefix)
      page_size = DatabaseHeader.page_size_from(prefix)
      buffer = Bytes.new(page_size)
      if @main.read_at(0, buffer) < page_size
        raise CorruptDatabase.new("file is shorter than one page", 1_u32)
      end
      buffer
    end

    # fileformat2.html §1.3.7: the in-header size when valid, otherwise the
    # file size. A committed WAL transaction records its own size.
    private def count_pages(header : DatabaseHeader, wal : WalReader?) : UInt32
      return wal.committed_page_count if wal
      # sqlite3WalDbsize: the snapshot's size, when the WAL records one.
      if (log = @wal_log) && log.reading? && log.database_page_count > 0
        return log.database_page_count
      end
      file_pages = (@main.size // header.page_size)
      # A WAL database before its snapshot is read (at open, or while
      # another connection recovers the WAL): the file may be shorter than
      # the header says until a checkpoint finishes, and the first read
      # takes the size from the WAL. Once a snapshot is read the check is
      # C's (sqlite3WalDbsize, then lockBtree).
      log = @wal_log
      snapshot_pending = log ? !log.reading? : @log_pending
      if snapshot_pending && header.read_format_version == 2 && header.header_page_count_valid?
        return Math.max(header.header_page_count, file_pages.to_u32)
      end
      if header.header_page_count_valid?
        if header.header_page_count > file_pages
          raise CorruptDatabase.new("header says #{header.header_page_count} pages but the file holds #{file_pages}", 1_u32)
        end
        return header.header_page_count
      end
      raise CorruptDatabase.new("file holds more than #{Limits::MAX_PAGE_NUMBER} pages", 1_u32) if file_pages > Limits::MAX_PAGE_NUMBER
      file_pages.to_u32
    end

    protected def get_u32(bytes : Bytes, offset : Int32) : UInt32
      (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) | (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3]
    end

    protected def put_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
      bytes[offset] = (value >> 24).to_u8!
      bytes[offset + 1] = (value >> 16).to_u8!
      bytes[offset + 2] = (value >> 8).to_u8!
      bytes[offset + 3] = value.to_u8!
    end
  end
end
