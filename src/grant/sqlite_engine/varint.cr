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
      # Most varints are one or two bytes (cell sizes, rowids below 16384);
      # those are decoded where they are used.
      if 0 <= offset && offset + 1 < limit && offset + 1 < bytes.size
        first = bytes.unsafe_fetch(offset)
        return {first.to_i64, 1} if first < 0x80_u8
        second = bytes.unsafe_fetch(offset + 1)
        return {((first & 0x7f_u8).to_i64 << 7) | second, 2} if second < 0x80_u8
      elsif 0 <= offset < limit && offset < bytes.size
        first = bytes.unsafe_fetch(offset)
        return {first.to_i64, 1} if first < 0x80_u8
      end
      {% if flag?(:x86_64) && !flag?(:grant_generic_kernels) && compare_versions(Crystal::VERSION, "1.20.0") >= 0 %}
        return decode_long_with_bit_extract(bytes, offset, limit) if ProcessorKernels::X86_64_V3
      {% end %}
      decode_long(bytes, offset, limit)
    end

    # The name of the body `decode` runs for a varint of two bytes or more
    # on this processor (`ProcessorKernels`). AArch64 keeps the generic body:
    # a branch-free shift-and-mask body measured 2.1x faster on varints of
    # mixed length but 15-25% slower on the 3-byte rowids that B-tree seeks
    # decode (Neoverse-N2, Apple M1 Max, 2026-11-27).
    def self.decode_variant : String
      {% if flag?(:x86_64) && !flag?(:grant_generic_kernels) && compare_versions(Crystal::VERSION, "1.20.0") >= 0 %}
        return "x86-64-v3" if ProcessorKernels::X86_64_V3
      {% end %}
      "generic"
    end

    # `decode` for a varint of two bytes or more (or one out of range): the
    # generic body, the reference every variant matches.
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

{% if flag?(:x86_64) && compare_versions(Crystal::VERSION, "1.20.0") >= 0 %}
  module Grant::SQLiteEngine
    module Varint
      lib LibBitManipulation
        fun parallel_bits_extract = "llvm.x86.bmi.pext.64"(source : UInt64, mask : UInt64) : UInt64
      end

      # The seven value bits of each of eight bytes.
      private SEVEN_BIT_MASK = 0x7f7f_7f7f_7f7f_7f7f_u64
      # The continuation bit of each of eight bytes.
      private CONTINUATION_BITS = 0x8080_8080_8080_8080_u64

      # `decode_long` on x86-64-v3 (BMI2 `pext`, LZCNT, MOVBE): one 8-byte
      # big-endian load, the first byte without its continuation bit found
      # by counting leading zeros, and the value bits gathered by `pext`
      # in one instruction. A varint within 9 bytes of *limit* takes the
      # generic body, which checks every byte against it.
      @[TargetFeature("+bmi,+bmi2,+lzcnt,+movbe")]
      def self.decode_long_with_bit_extract(bytes : Bytes, offset : Int32, limit : Int32) : {Int64, Int32}
        end_of_bytes = Math.min(limit, bytes.size)
        return decode_long(bytes, offset, limit) unless 0 <= offset && offset <= end_of_bytes - 9
        word = 0_u64
        pointerof(word).as(UInt8*).copy_from(bytes.to_unsafe + offset, 8)
        word = word.byte_swap
        stops = ~word & CONTINUATION_BITS
        if stops == 0
          value = (LibBitManipulation.parallel_bits_extract(word, SEVEN_BIT_MASK) << 8) | bytes.unsafe_fetch(offset + 8)
          return {value.to_i64!, 9}
        end
        length = stops.leading_zeros_count // 8 + 1
        value = LibBitManipulation.parallel_bits_extract(word >> (64 - 8 * length), SEVEN_BIT_MASK)
        {value.to_i64!, length.to_i32}
      end
    end
  end
{% end %}
