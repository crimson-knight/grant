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

    # Compares a stored index record with *key* straight from its bytes,
    # as sqlite3VdbeRecordCompare does with an unpacked key: numbers, NULLs,
    # blobs and UTF-8 text under BINARY or NOCASE compare without decoding
    # the record. Nil when a column needs the decoded value (RTRIM, UTF-16
    # text) or the record is malformed, so the caller decodes it (and
    # reports the corruption).
    def compare_record(payload : Bytes, key : Array(Value)) : Int32?
      header_size, length = Varint.decode(payload, 0)
      return if length == 0 || header_size < length || header_size > payload.size
      header_end = header_size.to_i32
      position = length
      body = header_end
      index = 0
      while position < header_end && index < key.size
        serial_type, used = Varint.decode(payload, position, header_end)
        return if used == 0
        position += used
        size = KeyComparator.stored_size(serial_type)
        return if size < 0 || body + size > payload.size
        column = @list_of_key_columns[index]? || ASCENDING_BINARY
        result = compare_stored(payload, body, serial_type, size, key.unsafe_fetch(index), column.collation)
        return unless result
        return column.descending ? -result : result if result != 0
        body += size
        index += 1
      end
      0
    end

    # Content bytes of a serial type; -1 for a reserved or negative one.
    protected def self.stored_size(serial_type : Int64) : Int32
      case serial_type
      when 0, 8, 9 then 0
      when 1, 2, 3, 4
        serial_type.to_i32
      when 5    then 6
      when 6, 7 then 8
      when 10, 11
        -1
      else
        serial_type < 0 || serial_type > Int32::MAX ? -1 : ((serial_type - 12) // 2).to_i32
      end
    end

    private def compare_stored(payload : Bytes, offset : Int32, serial_type : Int64, size : Int32, right : Value,
                               collation : Collation) : Int32?
      case serial_type
      when 0
        return compare_values(nil, right, collation)
      when 1, 2, 3, 4, 5, 6
        value = payload.unsafe_fetch(offset).to_i8!.to_i64
        (1...size).each { |step| value = (value << 8) | payload.unsafe_fetch(offset + step) }
        # An integer key against an integer, the usual index seek, is the
        # comparison compare_values ends with for two integers.
        return value <=> right if right.is_a?(Int64)
        return compare_values(value, right, collation)
      when 7
        bits = 0_u64
        8.times { |step| bits = (bits << 8) | payload.unsafe_fetch(offset + step) }
        real = bits.unsafe_as(Float64)
        return compare_values(real.nan? ? nil : real, right, collation)
      when 8 then return compare_values(0_i64, right, collation)
      when 9 then return compare_values(1_i64, right, collation)
      end
      text = serial_type.odd?
      left_class = text ? 2 : 3
      right_class = storage_class(right)
      return left_class <=> right_class if left_class != right_class
      stored = payload[offset, size]
      if right.is_a?(Bytes)
        return sign(stored <=> right)
      end
      return unless right.is_a?(String) && @encoding.utf8?
      case collation
      when .binary? then sign(stored <=> right.to_slice)
      when .no_case?
        right_bytes = right.to_slice
        shorter = Math.min(stored.size, right_bytes.size)
        shorter.times do |step|
          difference = ascii_lower(stored.unsafe_fetch(step)).to_i32 - ascii_lower(right_bytes.unsafe_fetch(step)).to_i32
          return sign(difference) if difference != 0
        end
        sign(stored.size - right_bytes.size)
      end
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
