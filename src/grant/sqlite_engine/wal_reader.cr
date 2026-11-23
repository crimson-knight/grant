module Grant::SQLiteEngine
  # Reads a `-wal` file (walformat.html §1, fileformat2.html §4): the 32-byte
  # header and the frames after it, verifying salts and the cumulative
  # checksums, and keeps the frames of committed transactions only.
  #
  # The wal-index (`-shm`) is not read or written: the reader recovers the
  # committed frames from the WAL itself, as SQLite does when the first
  # connection opens a database whose WAL was not checkpointed.
  class WalReader
    HEADER_SIZE       =             32
    FRAME_HEADER_SIZE =             24
    MAGIC_LITTLE      = 0x377f0682_u32
    MAGIC_BIG         = 0x377f0683_u32
    FORMAT_VERSION    =    3007000_u32

    # Page size the WAL was written with.
    getter page_size : Int32
    # Database size in pages after the last committed transaction.
    getter committed_page_count : UInt32
    # Number of frames that belong to committed transactions.
    getter committed_frame_count : Int32
    getter checkpoint_sequence : UInt32
    getter salt1 : UInt32
    getter salt2 : UInt32

    # Returns nil when *source* holds no usable WAL: shorter than its header,
    # a wrong magic number, a wrong header checksum, or no committed frame.
    # SQLite ignores such a WAL in recovery, and so does the reader.
    def self.read?(source : ByteSource) : WalReader?
      return nil if source.size < HEADER_SIZE
      header = Bytes.new(HEADER_SIZE)
      return nil if source.read_at(0, header) < HEADER_SIZE
      magic = big_endian_u32(header, 0)
      return nil unless magic.in?(MAGIC_LITTLE, MAGIC_BIG)
      big_endian_checksums = magic == MAGIC_BIG
      if big_endian_u32(header, 4) != FORMAT_VERSION
        raise CorruptDatabase.new("WAL format version #{big_endian_u32(header, 4)} is not #{FORMAT_VERSION}")
      end
      page_size = big_endian_u32(header, 8)
      valid_page_size = page_size >= Limits::MIN_PAGE_SIZE && page_size <= Limits::MAX_PAGE_SIZE && (page_size & (page_size - 1)) == 0
      return nil unless valid_page_size
      checksum = checksum(header[0, 24], {0_u32, 0_u32}, big_endian_checksums)
      return nil unless checksum == {big_endian_u32(header, 24), big_endian_u32(header, 28)}
      reader = new(source, header, page_size.to_i32, checksum, big_endian_checksums)
      reader.committed_frame_count > 0 ? reader : nil
    end

    protected def self.big_endian_u32(bytes : Bytes, offset : Int32) : UInt32
      (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) | (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3]
    end

    # The WAL checksum of walformat.html §1 ("Checksum Algorithm"): 32-bit
    # words in the byte order the magic number names, two running sums.
    protected def self.checksum(data : Bytes, seed : {UInt32, UInt32}, big_endian : Bool) : {UInt32, UInt32}
      sum0, sum1 = seed
      index = 0
      while index + 8 <= data.size
        word0 = read_word(data, index, big_endian)
        word1 = read_word(data, index + 4, big_endian)
        sum0 = sum0 &+ word0 &+ sum1
        sum1 = sum1 &+ word1 &+ sum0
        index += 8
      end
      {sum0, sum1}
    end

    private def self.read_word(data : Bytes, offset : Int32, big_endian : Bool) : UInt32
      if big_endian
        (data.unsafe_fetch(offset).to_u32 << 24) | (data.unsafe_fetch(offset + 1).to_u32 << 16) |
          (data.unsafe_fetch(offset + 2).to_u32 << 8) | data.unsafe_fetch(offset + 3)
      else
        (data.unsafe_fetch(offset + 3).to_u32 << 24) | (data.unsafe_fetch(offset + 2).to_u32 << 16) |
          (data.unsafe_fetch(offset + 1).to_u32 << 8) | data.unsafe_fetch(offset)
      end
    end

    @frame_offsets = {} of UInt32 => Int64

    protected def initialize(@source : ByteSource, header : Bytes, @page_size : Int32, header_checksum : {UInt32, UInt32}, big_endian : Bool)
      @checkpoint_sequence = WalReader.big_endian_u32(header, 12)
      @salt1 = WalReader.big_endian_u32(header, 16)
      @salt2 = WalReader.big_endian_u32(header, 20)
      @committed_page_count = 0_u32
      @committed_frame_count = 0
      scan_frames(header_checksum, big_endian)
    end

    # Reads every frame in order and stops at the first frame whose salts or
    # checksum do not match (the end of the valid log). Frames after the last
    # commit frame belong to an unfinished transaction and are dropped.
    private def scan_frames(seed : {UInt32, UInt32}, big_endian : Bool) : Nil
      frame_size = FRAME_HEADER_SIZE + @page_size
      frame = Bytes.new(frame_size)
      pending = {} of UInt32 => Int64
      checksum = seed
      offset = HEADER_SIZE.to_i64
      frame_index = 0
      while offset + frame_size <= @source.size
        break if @source.read_at(offset, frame) < frame_size
        page_number = WalReader.big_endian_u32(frame, 0)
        commit_page_count = WalReader.big_endian_u32(frame, 4)
        break if page_number == 0
        break unless WalReader.big_endian_u32(frame, 8) == @salt1 && WalReader.big_endian_u32(frame, 12) == @salt2
        checksum = WalReader.checksum(frame[0, 8], checksum, big_endian)
        checksum = WalReader.checksum(frame[FRAME_HEADER_SIZE, @page_size], checksum, big_endian)
        break unless checksum == {WalReader.big_endian_u32(frame, 16), WalReader.big_endian_u32(frame, 20)}
        pending[page_number] = offset + FRAME_HEADER_SIZE
        frame_index += 1
        if commit_page_count != 0
          @frame_offsets.merge!(pending)
          pending.clear
          @committed_page_count = commit_page_count
          @committed_frame_count = frame_index
        end
        offset += frame_size
      end
    end

    # Reads the latest committed copy of *page_number* into *buffer* and
    # returns true, or returns false when the WAL holds no committed copy.
    def read_page(page_number : UInt32, buffer : Bytes) : Bool
      offset = @frame_offsets[page_number]?
      return false unless offset
      read = @source.read_at(offset, buffer[0, @page_size])
      raise CorruptDatabase.new("WAL frame for page #{page_number} is truncated", page_number) if read < @page_size
      true
    end

    # True when the WAL holds a committed copy of *page_number*.
    def has_page?(page_number : UInt32) : Bool
      @frame_offsets.has_key?(page_number)
    end

    def close : Nil
      @source.close
    end
  end
end
