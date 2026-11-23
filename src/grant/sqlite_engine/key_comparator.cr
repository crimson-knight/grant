module Grant::SQLiteEngine
  # The built-in collating sequences (datatype3.html §7.1).
  enum Collation
    Binary
    NoCase
    RTrim

    # The collation named *name* (case-insensitive). Raises `UnsupportedSQL`
    # for an application-defined collation.
    def self.named(name : String) : Collation
      case name.upcase
      when "BINARY" then Binary
      when "NOCASE" then NoCase
      when "RTRIM"  then RTrim
      else
        raise UnsupportedSQL.new("collating sequence #{name}")
      end
    end
  end

  # How one column of a key sorts.
  record KeyColumn, collation : Collation, descending : Bool

  # Orders index records the way sqlite3VdbeRecordCompare does: NULL before
  # numbers, numbers (INTEGER and REAL compared by value) before text, text
  # (by the column's collation) before blobs, each column flipped when it is
  # DESC. Columns past the key columns sort BINARY ascending.
  class KeyComparator
    getter list_of_key_columns : Array(KeyColumn)

    ASCENDING_BINARY = KeyColumn.new(Collation::Binary, false)

    def initialize(@list_of_key_columns : Array(KeyColumn), @encoding : TextEncoding)
    end

    # Compares the first *count* values of two records.
    def compare(left : Array(Value), right : Array(Value), count : Int32 = Math.min(left.size, right.size)) : Int32
      count.times do |index|
        column = @list_of_key_columns[index]? || ASCENDING_BINARY
        result = compare_values(left[index]?, right[index]?, column.collation)
        return column.descending ? -result : result if result != 0
      end
      0
    end

    def compare_values(left : Value, right : Value, collation : Collation) : Int32
      left_class = storage_class(left)
      right_class = storage_class(right)
      return left_class <=> right_class if left_class != right_class
      if left.is_a?(Int64)
        return left <=> right if right.is_a?(Int64)
        return KeyComparator.integer_real_compare(right, left) if right.is_a?(Float64)
      elsif left.is_a?(Float64)
        return (left <=> right) || 0 if right.is_a?(Float64)
        return -KeyComparator.integer_real_compare(left, right) if right.is_a?(Int64)
      elsif left.is_a?(String)
        return compare_text(left, right, collation) if right.is_a?(String)
      elsif left.is_a?(Bytes)
        return sign(left <=> right) if right.is_a?(Bytes)
      end
      0
    end

    # Compares an INTEGER with a REAL exactly (sqlite3IntFloatCompare):
    # negative when *integer* is less than *real*.
    def self.integer_real_compare(real : Float64, integer : Int64) : Int32
      return 1 if real < -StoredValue::TWO_TO_THE_63
      return -1 if real >= StoredValue::TWO_TO_THE_63
      truncated = real.to_i64
      return -1 if integer < truncated
      return 1 if integer > truncated
      as_real = integer.to_f64
      return -1 if as_real < real
      return 1 if as_real > real
      0
    end

    private def compare_text(left : String, right : String, collation : Collation) : Int32
      case collation
      when .no_case?
        left_bytes = left.to_slice
        right_bytes = right.to_slice
        shorter = Math.min(left_bytes.size, right_bytes.size)
        shorter.times do |index|
          difference = ascii_lower(left_bytes.unsafe_fetch(index)).to_i32 - ascii_lower(right_bytes.unsafe_fetch(index)).to_i32
          return sign(difference) if difference != 0
        end
        sign(left_bytes.size - right_bytes.size)
      when .r_trim?
        sign(left.rstrip(' ').to_slice <=> right.rstrip(' ').to_slice)
      else
        return sign(left.to_slice <=> right.to_slice) if @encoding.utf8?
        sign(RecordEncoder.text_bytes(left, @encoding) <=> RecordEncoder.text_bytes(right, @encoding))
      end
    end

    private def ascii_lower(byte : UInt8) : UInt8
      byte >= 0x41_u8 && byte <= 0x5a_u8 ? byte + 32 : byte
    end

    private def storage_class(value : Value) : Int32
      case value
      when Nil            then 0
      when Int64, Float64 then 1
      when String         then 2
      else                     3
      end
    end

    private def sign(value : Int32) : Int32
      value <=> 0
    end
  end
end
