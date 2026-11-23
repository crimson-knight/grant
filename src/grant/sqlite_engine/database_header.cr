module Grant::SQLiteEngine
  # Text encoding of a database (header offset 56).
  enum TextEncoding
    UTF8    = 1
    UTF16LE = 2
    UTF16BE = 3
  end

  # The 100-byte database header at the start of page 1
  # (fileformat2.html §1.3). Every field is decoded; the checks the
  # specification calls mandatory raise `CorruptDatabase`.
  struct DatabaseHeader
    SIZE  = 100
    MAGIC = "SQLite format 3\0".to_slice

    getter page_size : Int32
    getter write_format_version : UInt8
    getter read_format_version : UInt8
    getter reserved_bytes_per_page : UInt8
    getter max_embedded_payload_fraction : UInt8
    getter min_embedded_payload_fraction : UInt8
    getter leaf_payload_fraction : UInt8
    getter file_change_counter : UInt32
    getter header_page_count : UInt32
    getter first_freelist_trunk_page : UInt32
    getter freelist_page_count : UInt32
    getter schema_cookie : UInt32
    getter schema_format : UInt32
    getter default_page_cache_size : Int32
    getter largest_root_btree_page : UInt32
    getter text_encoding : TextEncoding
    getter user_version : Int32
    getter incremental_vacuum_mode : UInt32
    getter application_id : Int32
    getter version_valid_for : UInt32
    getter sqlite_version_number : UInt32

    # Decodes the first 100 bytes of *bytes* (page 1).
    def self.parse(bytes : Bytes) : DatabaseHeader
      raise CorruptDatabase.new("file is shorter than the 100-byte header", 1_u32) if bytes.size < SIZE
      check_magic(bytes)
      new(bytes)
    end

    # Raises unless *bytes* starts with the 16-byte magic string.
    def self.check_magic(bytes : Bytes) : Nil
      unless bytes.size >= 16 && bytes[0, 16] == MAGIC
        raise CorruptDatabase.new("header magic string is not \"SQLite format 3\"", 1_u32)
      end
    end

    # Reads only the page size field, which is needed before page 1 can be
    # read whole.
    def self.page_size_from(bytes : Bytes) : Int32
      raw = big_endian_u16(bytes, 16)
      page_size = raw == 1 ? Limits::MAX_PAGE_SIZE : raw.to_i32
      valid = page_size >= Limits::MIN_PAGE_SIZE && page_size <= Limits::MAX_PAGE_SIZE && (page_size & (page_size - 1)) == 0
      raise CorruptDatabase.new("page size #{raw} is not a power of two from 512 to 65536", 1_u32) unless valid
      page_size
    end

    protected def self.big_endian_u16(bytes : Bytes, offset : Int32) : UInt16
      (bytes[offset].to_u16 << 8) | bytes[offset + 1]
    end

    protected def self.big_endian_u32(bytes : Bytes, offset : Int32) : UInt32
      (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) | (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3]
    end

    private def initialize(bytes : Bytes)
      @page_size = DatabaseHeader.page_size_from(bytes)
      @write_format_version = bytes[18]
      @read_format_version = bytes[19]
      # fileformat2.html §1.3.3: versions 1 (legacy) and 2 (WAL). A larger
      # read version means the file cannot be read.
      raise CorruptDatabase.new("read format version #{@read_format_version} is not 1 or 2", 1_u32) unless @read_format_version.in?(1_u8, 2_u8)
      @reserved_bytes_per_page = bytes[20]
      @max_embedded_payload_fraction = bytes[21]
      @min_embedded_payload_fraction = bytes[22]
      @leaf_payload_fraction = bytes[23]
      # fileformat2.html §1.3.5: these must be 64, 32 and 32.
      unless @max_embedded_payload_fraction == 64 && @min_embedded_payload_fraction == 32 && @leaf_payload_fraction == 32
        raise CorruptDatabase.new("payload fractions are not 64, 32, 32", 1_u32)
      end
      if usable_size < Limits::MIN_USABLE_SIZE
        raise CorruptDatabase.new("usable page size #{usable_size} is below #{Limits::MIN_USABLE_SIZE}", 1_u32)
      end
      @file_change_counter = DatabaseHeader.big_endian_u32(bytes, 24)
      @header_page_count = DatabaseHeader.big_endian_u32(bytes, 28)
      @first_freelist_trunk_page = DatabaseHeader.big_endian_u32(bytes, 32)
      @freelist_page_count = DatabaseHeader.big_endian_u32(bytes, 36)
      @schema_cookie = DatabaseHeader.big_endian_u32(bytes, 40)
      @schema_format = DatabaseHeader.big_endian_u32(bytes, 44)
      @default_page_cache_size = DatabaseHeader.big_endian_u32(bytes, 48).to_i32!
      @largest_root_btree_page = DatabaseHeader.big_endian_u32(bytes, 52)
      encoding_code = DatabaseHeader.big_endian_u32(bytes, 56)
      # fileformat2.html §1.3.13: a new, empty database has 0 here and takes
      # UTF-8.
      encoding_code = 1_u32 if encoding_code == 0
      encoding = encoding_code <= 3 ? TextEncoding.from_value?(encoding_code.to_i32) : nil
      raise CorruptDatabase.new("text encoding #{encoding_code} is not 1, 2 or 3", 1_u32) unless encoding
      @text_encoding = encoding
      @user_version = DatabaseHeader.big_endian_u32(bytes, 60).to_i32!
      @incremental_vacuum_mode = DatabaseHeader.big_endian_u32(bytes, 64)
      @application_id = DatabaseHeader.big_endian_u32(bytes, 68).to_i32!
      @version_valid_for = DatabaseHeader.big_endian_u32(bytes, 92)
      @sqlite_version_number = DatabaseHeader.big_endian_u32(bytes, 96)
    end

    # Page size minus the reserved bytes at the end of each page.
    def usable_size : Int32
      @page_size - @reserved_bytes_per_page.to_i32
    end

    # True when the in-header page count may be trusted: nonzero, and written
    # by a SQLite that also updated the change counter (fileformat2.html §1.3.7).
    def header_page_count_valid? : Bool
      @header_page_count != 0 && @file_change_counter == @version_valid_for
    end

    # True when the file was written with auto-vacuum or incremental vacuum,
    # so it has pointer-map pages (fileformat2.html §1.3.11).
    def has_pointer_map_pages? : Bool
      @largest_root_btree_page != 0
    end
  end
end
