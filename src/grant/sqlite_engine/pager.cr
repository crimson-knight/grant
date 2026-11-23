module Grant::SQLiteEngine
  # Reads pages by number from the database file, overlaid with the committed
  # frames of the WAL when one exists. Read-only; caches recently read pages.
  class Pager
    # fileformat2.html §1.3: the lock-byte page holds the byte range at
    # offset 2^30 and is never used for content.
    PENDING_BYTE_OFFSET = 1_073_741_824_i64

    # Pages kept in memory before the cache is emptied and refilled.
    DEFAULT_CACHE_PAGES = 4_096

    getter header : DatabaseHeader?
    getter page_size : Int32
    getter usable_size : Int32
    getter page_count : UInt32
    getter wal : WalReader?

    @cache = {} of UInt32 => Bytes

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

    # Returns the page bytes. Raises `CorruptDatabase` when *page_number* is
    # 0, past the end of the database, or the lock-byte page.
    def read_page(page_number : UInt32) : Bytes
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
      @main.close
      @wal.try &.close
      @cache.clear
    end

    private def read_first_page(wal : WalReader?) : Bytes?
      if wal
        buffer = Bytes.new(wal.page_size)
        return buffer if wal.read_page(1_u32, buffer)
      end
      return nil if @main.size == 0
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
  end
end
