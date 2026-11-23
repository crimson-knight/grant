module Grant::SQLiteEngine
  # SQLite's variable-length integer: one to nine bytes, big-endian, seven
  # bits per byte with the high bit as a continuation flag, and all eight bits
  # of the ninth byte (fileformat2.html §1.6).
  module Varint
    # Decodes the varint at *offset*, which must end before *limit*. Returns
    # the value and the number of bytes it used, or a length of 0 when the
    # varint runs past *limit* (the caller names the page in its error).
    def self.decode(bytes : Bytes, offset : Int32, limit : Int32 = bytes.size) : {Int64, Int32}
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
