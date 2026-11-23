module Grant::SQLiteEngine
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

    @cache = {} of UInt32 => Bytes

    # Read-write state.
    @file : DatabaseFile? = nil
    @file_system : FileSystem? = nil
    @path = ""
    @new_page_size = Limits::DEFAULT_PAGE_SIZE
    @new_text_encoding = TextEncoding::UTF8
    @dirty = {} of UInt32 => Bytes
    @journal_images = {} of UInt32 => Bytes
    @original_page_count = 0_u32
    @in_write_transaction = false
    @read_depth = 0
    @statement_images : Hash(UInt32, Bytes?)? = nil
    @statement_page_count = 0_u32

    # A database with no pages (a zero-length file and no WAL) is an empty
    # database, as in SQLite.
    def initialize(@main : ByteSource, wal_source : ByteSource? = nil, @cache_pages : Int32 = DEFAULT_CACHE_PAGES)
      wal = wal_source ? WalReader.read?(wal_source) : nil
      wal_source.close if wal_source && wal.nil?
      @wal = wal
      @page_size = 0
      @usable_size = 0
      @page_count = 0_u32
      @header = nil
      load_first_page
    end

    # Opens *path* for reading and writing through *file_system*, creating
    # an empty database when the file does not exist. A hot journal left by
    # a crash is rolled back first. *page_size* and *text_encoding* apply
    # only when the first transaction creates the database. *cache_pages*
    # bounds the clean pages kept in memory; nil sizes the cache as SQLite's
    # default of 2,000 KiB.
    def self.open_read_write(file_system : FileSystem, path : String, cache_pages : Int32? = nil,
                             page_size : Int32 = Limits::DEFAULT_PAGE_SIZE,
                             text_encoding : TextEncoding = TextEncoding::UTF8) : Pager
      valid_size = page_size >= Limits::MIN_PAGE_SIZE && page_size <= Limits::MAX_PAGE_SIZE && (page_size & (page_size - 1)) == 0
      raise ArgumentError.new("page_size #{page_size} is not a power of two from 512 to 65536") unless valid_size
      file = file_system.open(path)
      wal_path = "#{path}-wal"
      wal = file_system.exists?(wal_path) ? file_system.open(wal_path) : nil
      begin
        raise Busy.new unless file.lock(LockLevel::Shared)
        begin
          roll_back_hot_journal(file_system, path, file)
          pager = new(file, wal)
        ensure
          file.unlock(LockLevel::None)
        end
        pager.attach_writer(file_system, path, file, page_size, text_encoding, cache_pages)
        pager
      rescue error
        file.close
        wal.try &.close
        raise error
      end
    end

    protected def attach_writer(@file_system : FileSystem, @path : String, @file : DatabaseFile, @new_page_size : Int32,
                                @new_text_encoding : TextEncoding, cache_pages : Int32?) : Nil
      page_size = @page_size > 0 ? @page_size : @new_page_size
      @cache_pages = cache_pages || Math.max(16, Limits::DEFAULT_CACHE_KIBIBYTES * 1024 // page_size)
    end

    def writable? : Bool
      !@file.nil?
    end

    def in_write_transaction? : Bool
      @in_write_transaction
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
        return cached
      end
      check_page_number(page_number)
      buffer = Bytes.new(@page_size)
      wal = @wal
      unless wal && wal.read_page(page_number, buffer)
        offset = (page_number.to_i64 - 1) * @page_size
        read = @main.read_at(offset, buffer)
        raise CorruptDatabase.new("page is past the end of the file", page_number) if read < @page_size
      end
      @cache.clear if @cache.size >= @cache_pages
      @cache[page_number] = buffer
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

    def close : Nil
      rollback if @in_write_transaction
      if file = @file
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
      begin_read(file) if @read_depth == 0 && !@in_write_transaction
      @read_depth += 1
      begin
        yield
      ensure
        @read_depth -= 1
        file.unlock(LockLevel::None) if @read_depth == 0 && !@in_write_transaction
      end
    end

    private def begin_read(file : DatabaseFile) : Nil
      raise Busy.new unless file.lock(LockLevel::Shared)
      begin
        if Pager.roll_back_hot_journal(writer_file_system, @path, file)
          reload
        elsif changed_on_disk?(file)
          reload
        end
      rescue error
        file.unlock(LockLevel::None)
        raise error
      end
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
    # lock, and deletes it. Returns true when it rolled one back.
    protected def self.roll_back_hot_journal(file_system : FileSystem, path : String, file : DatabaseFile) : Bool
      journal_path = RollbackJournal.path_for(path)
      return false unless RollbackJournal.hot?(file_system, journal_path, file)
      held = file.lock_level
      raise Busy.new("database is locked (a hot journal needs an exclusive lock)") unless file.lock(LockLevel::Exclusive)
      begin
        journal = file_system.open(journal_path)
        begin
          RollbackJournal.play_back(journal, file)
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
    # connections may still read but not write. Raises `Busy` when another
    # connection is writing and `UnsupportedSQL` for a WAL or auto-vacuum
    # database.
    def begin_write : Nil
      file = @file
      raise ReadOnlyDatabase.new unless file
      raise Error.new("a write transaction is already open") if @in_write_transaction
      begin_read(file) if @read_depth == 0
      unless file.lock(LockLevel::Reserved)
        file.unlock(LockLevel::None) if @read_depth == 0
        raise Busy.new
      end
      if current_header = @header
        if @wal || current_header.write_format_version == 2
          file.unlock(LockLevel::None) if @read_depth == 0
          raise UnsupportedSQL.new("writing a database in WAL mode (journal_mode=WAL)")
        end
        if current_header.has_pointer_map_pages?
          file.unlock(LockLevel::None) if @read_depth == 0
          raise UnsupportedSQL.new("writing an auto_vacuum database")
        end
      end
      # A journal left behind that was not hot (empty, or zeroed) is stale.
      writer_file_system.delete(RollbackJournal.path_for(@path))
      @in_write_transaction = true
      @original_page_count = @page_count
      create_first_page if @page_count == 0
    end

    # Commits the open write transaction: takes the EXCLUSIVE lock, writes
    # and syncs the journal, writes and syncs the changed pages, then
    # deletes the journal, which is the moment the transaction commits.
    def commit : Nil
      file = writer_file
      raise Error.new("no write transaction is open") unless @in_write_transaction
      if @dirty.empty?
        finish_transaction(file)
        return
      end
      page_one = page_for_write(1_u32)
      counter = get_u32(page_one, CHANGE_COUNTER_OFFSET) &+ 1
      put_u32(page_one, CHANGE_COUNTER_OFFSET, counter)
      put_u32(page_one, PAGE_COUNT_OFFSET, @page_count)
      put_u32(page_one, VERSION_VALID_FOR_OFFSET, counter)
      put_u32(page_one, VERSION_NUMBER_OFFSET, WRITER_VERSION_NUMBER)
      raise Busy.new unless file.lock(LockLevel::Exclusive)
      file_system = writer_file_system
      journal_path = RollbackJournal.path_for(@path)
      journal = file_system.open(journal_path)
      begin
        images = @journal_images.keys.sort!.map { |page_number| {page_number, @journal_images[page_number]} }
        RollbackJournal.write(journal, @page_size, @original_page_count, images, Random.rand(UInt32))
      ensure
        journal.close
      end
      @dirty.keys.sort!.each do |page_number|
        file.write_at((page_number.to_i64 - 1) * @page_size, @dirty[page_number])
      end
      file.sync
      file_system.delete(journal_path)
      @dirty.each { |page_number, buffer| @cache[page_number] = buffer }
      @header = DatabaseHeader.parse(page_one)
      finish_transaction(file)
    end

    # Ends the open write transaction without writing anything.
    def rollback : Nil
      file = writer_file
      return unless @in_write_transaction
      @generation += 1
      @dirty.each_key { |page_number| @cache.delete(page_number) }
      @page_count = @original_page_count
      if @page_count == 0
        @page_size = 0
        @usable_size = 0
        @header = nil
        @cache.clear
      else
        @header = DatabaseHeader.parse(read_page_after_rollback(1_u32))
      end
      finish_transaction(file)
    end

    private def finish_transaction(file : DatabaseFile) : Nil
      @dirty.clear
      @journal_images.clear
      @statement_images = nil
      @in_write_transaction = false
      file.unlock(@read_depth > 0 ? LockLevel::Shared : LockLevel::None)
    end

    private def read_page_after_rollback(page_number : UInt32) : Bytes
      @cache.delete(page_number)
      read_page(page_number)
    end

    # Starts a statement inside the write transaction: a failed statement
    # puts back exactly the pages it changed (the statement journal).
    def begin_statement : Nil
      @statement_images = {} of UInt32 => Bytes?
      @statement_page_count = @page_count
    end

    def end_statement : Nil
      @statement_images = nil
    end

    def rollback_statement : Nil
      images = @statement_images
      return unless images
      @generation += 1
      images.each do |page_number, image|
        if image
          @dirty[page_number].copy_from(image.to_unsafe, image.size)
        else
          @dirty.delete(page_number)
          @cache.delete(page_number)
          @journal_images.delete(page_number)
        end
      end
      @page_count = @statement_page_count
      @statement_images = nil
      if @page_count > 0
        @header = DatabaseHeader.parse(read_page(1_u32))
      end
    end

    # The bytes of *page_number* to change in place; the page's original
    # image is kept for the journal the first time the transaction touches
    # it.
    def page_for_write(page_number : UInt32) : Bytes
      raise Error.new("no write transaction is open") unless @in_write_transaction
      if buffer = @dirty[page_number]?
        if images = @statement_images
          images[page_number] = buffer.dup unless images.has_key?(page_number)
        end
        return buffer
      end
      buffer = page_number <= @page_count ? read_page(page_number) : Bytes.new(@page_size)
      if page_number <= @original_page_count && !@journal_images.has_key?(page_number)
        @journal_images[page_number] = buffer.dup
      end
      if images = @statement_images
        images[page_number] = nil unless images.has_key?(page_number)
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
      @page_count = page_number
      @dirty[page_number] = Bytes.new(@page_size)
      if images = @statement_images
        images[page_number] = nil
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
      page = Bytes.new(@page_size)
      @dirty[1_u32] = page
      if images = @statement_images
        images[1_u32] = nil
      end
      page.copy_from(DatabaseHeader::MAGIC.to_unsafe, DatabaseHeader::MAGIC.size)
      page[16] = (@page_size == Limits::MAX_PAGE_SIZE ? 1 : @page_size >> 8).to_u8
      page[17] = (@page_size == Limits::MAX_PAGE_SIZE ? 0 : @page_size & 0xff).to_u8
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
      file_pages = (@main.size // header.page_size)
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
