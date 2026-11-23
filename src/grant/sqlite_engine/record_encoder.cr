module Grant::SQLiteEngine
  # Converts a value as SQLite does before storing it in a column
  # (datatype3.html §3, applyAffinity and OP_MakeRecord in vdbe.c), and
  # checks STRICT columns (stricttables.html).
  module StoredValue
    # 2^63 as a double, the first double past Int64::MAX.
    TWO_TO_THE_63 = 9.223372036854775808e18

    # Largest magnitude an INTEGER keeps in six bytes. A REAL-affinity value
    # that is a whole number inside it is stored as an integer; outside it,
    # as the eight-byte REAL (OP_MakeRecord, MEM_IntReal).
    SIX_BYTE_INTEGER_MAXIMUM = 140_737_488_355_327_i64

    # The value SQLite stores for *value* in a column of *affinity*.
    def self.for_affinity(affinity : Affinity, value : Value) : Value
      case affinity
      when .text?
        return value.to_s if value.is_a?(Int64)
        return real_text(value) if value.is_a?(Float64)
        value
      when .numeric?, .integer?
        numeric(value)
      when .real?
        real(numeric(value))
      else
        value
      end
    end

    # The value a comparison with a column of *affinity* uses (OP_Eq):
    # numeric affinities convert text only, TEXT affinity converts numbers,
    # and an INTEGER or REAL is compared exactly as it is.
    def self.for_comparison(affinity : Affinity, value : Value) : Value
      return for_affinity(affinity, value) if affinity.text?
      return value unless affinity.numeric? || affinity.integer? || affinity.real?
      return value unless value.is_a?(String)
      number = number_from_text(value)
      number.nil? ? value : number
    end

    # The value a STRICT column of *declared_type* stores, or raises
    # `ConstraintViolation` (Datatype) naming *column_name*.
    def self.for_strict_column(declared_type : String, column_name : String, value : Value) : Value
      return value if value.nil?
      upper = declared_type.upcase
      converted = case upper
                  when "INT", "INTEGER" then numeric(value)
                  when "REAL"           then real(numeric(value))
                  when "TEXT"           then for_affinity(Affinity::Text, value)
                  else                       value
                  end
      accepted = case upper
                 when "INT", "INTEGER" then converted.is_a?(Int64)
                 when "REAL"           then converted.is_a?(Int64) || converted.is_a?(Float64)
                 when "TEXT"           then converted.is_a?(String)
                 when "BLOB"           then converted.is_a?(Bytes)
                 else                       true
                 end
      unless accepted
        raise ConstraintViolation.new(ConstraintViolation::Kind::Datatype, "cannot store #{type_name(value)} value in #{upper} column #{column_name}")
      end
      converted
    end

    # A REAL as TEXT affinity stores it: 15 significant digits with a
    # decimal point in the mantissa ("%!.15g", sqlite3VdbeMemStringify in
    # SQLite 3.45 to 3.51), "Inf" and "-Inf", and -0.0 as "0.0". SQLite 3.52
    # and later print 17 digits when 15 do not read back the same double.
    def self.real_text(value : Float64) : String
      return value > 0 ? "Inf" : "-Inf" if value.infinite?
      return "0.0" if value == 0
      mantissa, separator, exponent = ("%.15g" % value).partition('e')
      mantissa = "#{mantissa}.0" unless mantissa.includes?('.')
      "#{mantissa}#{separator}#{exponent}"
    end

    # NUMERIC and INTEGER affinity: text that reads as a number becomes one,
    # and a REAL that is a whole number inside the Int64 range becomes an
    # INTEGER (sqlite3VdbeIntegerAffinity).
    def self.numeric(value : Value) : Value
      if value.is_a?(String)
        number = number_from_text(value)
        return number.nil? ? value : number
      end
      return whole_number(value) if value.is_a?(Float64)
      value
    end

    # REAL affinity on a value NUMERIC affinity already converted: whole
    # numbers in six bytes stay integers, larger ones become REAL.
    def self.real(value : Value) : Value
      if value.is_a?(Int64)
        return value if value >= -SIX_BYTE_INTEGER_MAXIMUM - 1 && value <= SIX_BYTE_INTEGER_MAXIMUM
        return value.to_f64
      end
      value
    end

    # The INTEGER a whole REAL equals, or the REAL itself.
    def self.whole_number(real : Float64) : Value
      return real unless real > -TWO_TO_THE_63 && real < TWO_TO_THE_63
      integer = real.to_i64
      integer.to_f64 == real && integer != Int64::MIN && integer != Int64::MAX ? integer : real
    end

    # sqlite3AtoF and sqlite3Atoi64: decimal text with optional surrounding
    # whitespace, sign, fraction and exponent. An integer that does not fit
    # Int64 is read as a REAL. Returns nil for text that is not a number.
    def self.number_from_text(text : String) : Value
      trimmed = text.strip(" \t\n\f\v\r")
      return unless trimmed.matches?(/\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\z/)
      unless trimmed.includes?('.') || trimmed.includes?('e') || trimmed.includes?('E')
        if integer = trimmed.lchop('+').to_i64?
          return integer
        end
      end
      real = Affinity.parse_real_literal(trimmed.lchop('+'))
      return unless real
      whole_number(real)
    end

    private def self.type_name(value : Value) : String
      case value
      when Int64   then "INTEGER"
      when Float64 then "REAL"
      when String  then "TEXT"
      else              "BLOB"
      end
    end
  end

  # Builds records (fileformat2.html §2.1): the header of serial types, then
  # the values, each integer in the fewest bytes that hold it.
  module RecordEncoder
    # Encodes *values*, text in *encoding*. Schema format 4 and later store
    # the integers 0 and 1 in the header alone (serial types 8 and 9).
    def self.encode(values : Array(Value), encoding : TextEncoding, schema_format : UInt32 = 4_u32) : Bytes
      list_of_serial_types = Array(Int64).new(values.size)
      list_of_contents = Array(Bytes?).new(values.size)
      header_body = 0
      content_size = 0_i64
      values.each do |value|
        content = nil
        serial_type = case value
                      when Nil     then 0_i64
                      when Int64   then integer_serial_type(value, schema_format)
                      when Float64 then value.nan? ? 0_i64 : 7_i64
                      when String
                        content = text_bytes(value, encoding)
                        content.size.to_i64 * 2 + 13
                      else
                        content = value
                        value.size.to_i64 * 2 + 12
                      end
        list_of_serial_types << serial_type
        list_of_contents << content
        header_body += Varint.size(serial_type)
        content_size += Record.content_size(serial_type, 0_u32)
      end
      header_size = header_body + 1
      while header_body + Varint.size(header_size.to_i64) != header_size
        header_size = header_body + Varint.size(header_size.to_i64)
      end
      total = header_size.to_i64 + content_size
      if total > Limits::MAX_RECORD_BYTES
        raise LimitExceeded.new("SQLITE_MAX_LENGTH", "a record of #{total} bytes is larger than #{Limits::MAX_RECORD_BYTES}")
      end
      record = Bytes.new(total.to_i32)
      position = Varint.encode(header_size.to_i64, record, 0)
      list_of_serial_types.each { |serial_type| position += Varint.encode(serial_type, record, position) }
      values.each_with_index do |value, index|
        serial_type = list_of_serial_types.unsafe_fetch(index)
        if content = list_of_contents.unsafe_fetch(index)
          (record + position).copy_from(content.to_unsafe, content.size)
          position += content.size
        elsif value.is_a?(Int64) && serial_type < 7
          position += write_integer(record, position, value, Record.content_size(serial_type, 0_u32).to_i32)
        elsif value.is_a?(Float64) && serial_type == 7
          position += write_integer(record, position, value.unsafe_as(Int64), 8)
        end
      end
      record
    end

    # The smallest serial type that holds *value*.
    def self.integer_serial_type(value : Int64, schema_format : UInt32) : Int64
      return 8_i64 + value if (value == 0 || value == 1) && schema_format >= 4
      magnitude = value < 0 ? ~value : value
      return 1_i64 if magnitude <= 127
      return 2_i64 if magnitude <= 32_767
      return 3_i64 if magnitude <= 8_388_607
      return 4_i64 if magnitude <= 2_147_483_647
      return 5_i64 if magnitude <= StoredValue::SIX_BYTE_INTEGER_MAXIMUM
      6_i64
    end

    # Text in the database encoding.
    def self.text_bytes(text : String, encoding : TextEncoding) : Bytes
      return text.to_slice if encoding.utf8?
      units = text.to_utf16
      bytes = Bytes.new(units.size * 2)
      units.each_with_index do |unit, index|
        high = (unit >> 8).to_u8!
        low = unit.to_u8!
        if encoding.utf16_le?
          bytes[index * 2] = low
          bytes[index * 2 + 1] = high
        else
          bytes[index * 2] = high
          bytes[index * 2 + 1] = low
        end
      end
      bytes
    end

    private def self.write_integer(record : Bytes, position : Int32, value : Int64, size : Int32) : Int32
      unsigned = value.to_u64!
      (size - 1).downto(0) do |index|
        record[position + index] = unsigned.to_u8!
        unsigned >>= 8
      end
      size
    end
  end
end
