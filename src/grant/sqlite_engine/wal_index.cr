module Grant::SQLiteEngine
  # The 48-byte wal-index header (walformat.html §2.1, WalIndexHdr), kept as
  # the bytes C SQLite stores: native byte order, except the salts, which
  # keep the WAL file's byte order. Two headers are equal when their bytes
  # are.
  struct WalIndexHeader
    SIZE          =            48
    VERSION       = 3_007_000_u32
    CHECKSUM_SIZE =            40

    getter bytes : Bytes

    def initialize(@bytes : Bytes = Bytes.new(SIZE))
    end

    def ==(other : WalIndexHeader) : Bool
      @bytes == other.bytes
    end

    def dup : WalIndexHeader
      WalIndexHeader.new(@bytes.dup)
    end

    private def get(offset : Int32) : UInt32
      IO::ByteFormat::SystemEndian.decode(UInt32, @bytes[offset, 4])
    end

    private def put(offset : Int32, value : UInt32) : Nil
      IO::ByteFormat::SystemEndian.encode(value, @bytes[offset, 4])
    end

    def version : UInt32
      get(0)
    end

    def change_count : UInt32
      get(8)
    end

    def change_count=(value : UInt32) : Nil
      put(8, value)
    end

    def initialized? : Bool
      @bytes[12] != 0
    end

    # szPage: 65,536 is stored as 1.
    def page_size : Int32
      raw = IO::ByteFormat::SystemEndian.decode(UInt16, @bytes[14, 2]).to_i32
      (raw & 0xfe00) + ((raw & 0x0001) << 16)
    end

    def page_size=(size : Int32) : Nil
      IO::ByteFormat::SystemEndian.encode(((size & 0xff00) | (size >> 16)).to_u16, @bytes[14, 2])
    end

    # The last frame of the last committed transaction (mxFrame).
    def max_frame : UInt32
      get(16)
    end

    def max_frame=(value : UInt32) : Nil
      put(16, value)
    end

    # The database size in pages after that transaction (nPage).
    def database_page_count : UInt32
      get(20)
    end

    def database_page_count=(value : UInt32) : Nil
      put(20, value)
    end

    # The cumulative frame checksum after the last committed frame.
    def frame_checksum : {UInt32, UInt32}
      {get(24), get(28)}
    end

    def frame_checksum=(value : {UInt32, UInt32}) : Nil
      put(24, value[0])
      put(28, value[1])
    end

    # The salts as the 8 bytes of the WAL header.
    def salt_bytes : Bytes
      @bytes[32, 8]
    end

    def salt_bytes=(salt : Bytes) : Nil
      @bytes[32, 8].copy_from(salt)
    end

    # walIndexTryHdr's checks: initialized and its checksum matches.
    def valid? : Bool
      initialized? && WalIndexHeader.checksum(@bytes) == {get(40), get(44)}
    end

    # walIndexWriteHdr's preparation: initialized, current version, checksum.
    def seal : Nil
      @bytes[12] = 1_u8
      put(0, VERSION)
      checksum = WalIndexHeader.checksum(@bytes)
      put(40, checksum[0])
      put(44, checksum[1])
    end

    # walChecksumBytes(1, ...) over the first 40 bytes: native words.
    def self.checksum(bytes : Bytes) : {UInt32, UInt32}
      sum0 = 0_u32
      sum1 = 0_u32
      index = 0
      while index < CHECKSUM_SIZE
        sum0 = sum0 &+ IO::ByteFormat::SystemEndian.decode(UInt32, bytes[index, 4]) &+ sum1
        sum1 = sum1 &+ IO::ByteFormat::SystemEndian.decode(UInt32, bytes[index + 4, 4]) &+ sum0
        index += 8
      end
      {sum0, sum1}
    end
  end

  # The layout of the wal-index (walformat.html §2): two copies of the
  # header, the checkpoint information (nBackfill, the read marks, the lock
  # bytes), then per 32 KiB region an array of page numbers by frame and a
  # hash table from page number to frame.
  module WalIndexLayout
    HEADER_COPY_TWO        =    48
    BACKFILL_OFFSET        =    96
    READ_MARK_OFFSET       =   100
    BACKFILL_ATTEMPTED     =   128
    INDEX_HEADER_SIZE      =   136
    PAGES_PER_REGION       = 4_096
    HASH_SLOTS             = 8_192
    FIRST_REGION_PAGES     = PAGES_PER_REGION - INDEX_HEADER_SIZE // 4
    HASH_MULTIPLIER        =         383_u32
    READER_COUNT           =               5
    READ_MARK_NOT_USED     = 0xffff_ffff_u32
    HASH_TABLE_BYTE_OFFSET = PAGES_PER_REGION * 4

    # Lock slots (wal.c).
    WRITE_LOCK   = 0
    CKPT_LOCK    = 1
    RECOVER_LOCK = 2

    def self.read_lock(index : Int32) : Int32
      3 + index
    end

    # walFramePage: the region holding *frame*.
    def self.region_of(frame : UInt32) : Int32
      ((frame.to_i64 + PAGES_PER_REGION - FIRST_REGION_PAGES - 1) // PAGES_PER_REGION).to_i32
    end

    # iZero of walHashGet: the frame number before the region's first.
    def self.first_frame_before(region : Int32) : UInt32
      region == 0 ? 0_u32 : (FIRST_REGION_PAGES + (region - 1) * PAGES_PER_REGION).to_u32
    end

    # Byte offset of the page-number array of *region* in the file.
    def self.page_array_offset(region : Int32) : Int32
      region * SharedMemory::REGION_SIZE + (region == 0 ? INDEX_HEADER_SIZE : 0)
    end

    def self.hash_table_offset(region : Int32) : Int32
      region * SharedMemory::REGION_SIZE + HASH_TABLE_BYTE_OFFSET
    end

    def self.hash(page_number : UInt32) : Int32
      ((page_number &* HASH_MULTIPLIER) & (HASH_SLOTS - 1)).to_i32
    end

    def self.read_mark_offset(index : Int32) : Int32
      READ_MARK_OFFSET + index * 4
    end
  end
end
