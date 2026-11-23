module Grant::SQLiteEngine
  # Comparison with the built-in collating sequences, for the query
  # executor: BINARY compares bytes, NOCASE folds the 26 ASCII letters,
  # RTRIM ignores trailing spaces. Ported from main.c `binCollFunc`,
  # `nocaseCollatingFunc` and `rtrimCollFunc`.
  enum Collation
    # The collation named *name* (case-insensitive), or nil when SQLite has
    # no built-in collation of that name.
    def self.named?(name : String) : Collation?
      case name.downcase
      when "binary" then Binary
      when "nocase" then NoCase
      when "rtrim"  then RTrim
      end
    end

    def compare(left : String, right : String) : Int32
      compare(left.to_slice, right.to_slice)
    end

    def compare(left : Bytes, right : Bytes) : Int32
      case self
      when NoCase
        Collation.compare_nocase(left, right)
      when RTrim
        left_size = left.size
        right_size = right.size
        while left_size > 0 && left.unsafe_fetch(left_size - 1) == 0x20_u8
          left_size -= 1
        end
        while right_size > 0 && right.unsafe_fetch(right_size - 1) == 0x20_u8
          right_size -= 1
        end
        Collation.compare_binary(left[0, left_size], right[0, right_size])
      else
        Collation.compare_binary(left, right)
      end
    end

    def self.compare_binary(left : Bytes, right : Bytes) : Int32
      shorter = Math.min(left.size, right.size)
      result = shorter == 0 ? 0 : LibC.memcmp(left.to_unsafe, right.to_unsafe, shorter)
      return result.sign if result != 0
      (left.size - right.size).sign
    end

    # sqlite3StrNICmp over the shorter length (stopping at a zero byte), then
    # the lengths.
    def self.compare_nocase(left : Bytes, right : Bytes) : Int32
      remaining = Math.min(left.size, right.size)
      index = 0
      while remaining > 0
        left_byte = left.unsafe_fetch(index)
        break if left_byte == 0
        break unless fold(left_byte) == fold(right.unsafe_fetch(index))
        index += 1
        remaining -= 1
      end
      if remaining > 0
        difference = fold(left.unsafe_fetch(index)).to_i32 - fold(right.unsafe_fetch(index)).to_i32
        return difference.sign if difference != 0
      end
      (left.size - right.size).sign
    end

    @[AlwaysInline]
    def self.fold(byte : UInt8) : UInt8
      byte >= 0x41_u8 && byte <= 0x5a_u8 ? byte + 32 : byte
    end

    # A key that is equal for two strings exactly when this collation calls
    # them equal, for hashing (DISTINCT, GROUP BY, IN sets).
    def equality_key(text : String) : String
      case self
      when NoCase
        bytes = text.to_slice
        return text unless bytes.any? { |byte| (byte >= 0x41_u8 && byte <= 0x5a_u8) || byte == 0_u8 }
        # Bytes after a zero byte are not compared, only counted.
        cut = bytes.index(0_u8) || bytes.size
        folded = String.new(Bytes.new(cut) { |index| Collation.fold(bytes[index]) })
        cut == bytes.size ? folded : "#{folded}\0#{bytes.size}"
      when RTrim
        text.rstrip(' ')
      else
        text
      end
    end
  end
end
