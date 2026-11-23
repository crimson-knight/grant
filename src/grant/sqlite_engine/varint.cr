module Grant::SQLiteEngine
  # SQLite's variable-length integer: one to nine bytes, big-endian, seven
  # bits per byte with the high bit as a continuation flag, and all eight bits
  # of the ninth byte (fileformat2.html §1.6).
  module Varint
    # Decodes the varint at *offset*, which must end before *limit*. Returns
    # the value and the number of bytes it used, or a length of 0 when the
    # varint runs past *limit* (the caller names the page in its error).
    @[AlwaysInline]
    def self.decode(bytes : Bytes, offset : Int32, limit : Int32 = bytes.size) : {Int64, Int32}
      # Most varints are one byte; that case is decoded where it is used.
      if 0 <= offset < limit && offset < bytes.size
        first = bytes.unsafe_fetch(offset)
        return {first.to_i64, 1} if first < 0x80_u8
      end
      decode_long(bytes, offset, limit)
    end

    # `decode` for a varint of two bytes or more (or one out of range).
    @[NoInline]
    def self.decode_long(bytes : Bytes, offset : Int32, limit : Int32) : {Int64, Int32}
      limit = Math.min(limit, bytes.size)
      result = 0_u64
      index = 0
      while index < 8
        position = offset + index
        return {0_i64, 0} if position >= limit
        byte = bytes.unsafe_fetch(position)
        result = (result << 7) | (byte & 0x7f_u8)
        return {result.to_i64!, index + 1} if byte < 0x80_u8
        index += 1
      end
      position = offset + 8
      return {0_i64, 0} if position >= limit
      result = (result << 8) | bytes.unsafe_fetch(position)
      {result.to_i64!, 9}
    end
  end
end

module Grant::SQLiteEngine
  module Varint
    # Bytes *value* takes as a varint.
    def self.size(value : Int64) : Int32
      unsigned = value.to_u64!
      return 9 if unsigned > 0x00ff_ffff_ffff_ffff_u64
      length = 1
      while unsigned > 0x7f_u64
        unsigned >>= 7
        length += 1
      end
      length
    end

    # Writes *value* at *offset* and returns the bytes written
    # (fileformat2.html §1.6, sqlite3PutVarint).
    def self.encode(value : Int64, bytes : Bytes, offset : Int32) : Int32
      unsigned = value.to_u64!
      if unsigned > 0x00ff_ffff_ffff_ffff_u64
        bytes[offset + 8] = unsigned.to_u8!
        unsigned >>= 8
        7.downto(0) do |index|
          bytes[offset + index] = ((unsigned & 0x7f_u64) | 0x80_u64).to_u8!
          unsigned >>= 7
        end
        return 9
      end
      length = size(value)
      (length - 1).downto(0) do |index|
        byte = (unsigned & 0x7f_u64).to_u8!
        byte |= 0x80_u8 if index < length - 1
        bytes[offset + index] = byte
        unsigned >>= 7
      end
      length
    end
  end
end
