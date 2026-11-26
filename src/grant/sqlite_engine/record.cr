module Grant::SQLiteEngine
  # Decodes the record format (fileformat2.html §2.1): a header of serial
  # types followed by the values.
  module Record
    # SQLite's hard upper bound on columns in a record (SQLITE_MAX_COLUMN can
    # be raised to 32,767 at most).
    MAX_RECORD_COLUMNS = 32_767

    # Decodes every value of *payload*. *page_number* names the page in a
    # corruption error. With *buffer* the values are decoded into it (its
    # old contents cleared) and it is returned, so a caller that reads one
    # row at a time allocates no array per row.
    def self.decode(payload : Bytes, encoding : TextEncoding, page_number : UInt32,
                    buffer : Array(Value)? = nil) : Array(Value)
      header_size, length = Varint.decode(payload, 0)
      corrupt(page_number, "record header varint is truncated") if length == 0
      if header_size < length || header_size > payload.size
        corrupt(page_number, "record header size #{header_size} is outside #{length}..#{payload.size}")
      end
      header_end = header_size.to_i32
      position = length
      body = header_end
      # Most serial types take one header byte, so the header size is a
      # close estimate of the column count.
      values = buffer ? buffer.clear : Array(Value).new(header_end - length)
      while position < header_end
        serial_type, used = Varint.decode(payload, position, header_end)
        corrupt(page_number, "record serial type varint is truncated") if used == 0
        position += used
        corrupt(page_number, "record has more than #{MAX_RECORD_COLUMNS} columns") if values.size >= MAX_RECORD_COLUMNS
        size = content_size(serial_type, page_number)
        if body.to_i64 + size > payload.size
          corrupt(page_number, "record value of serial type #{serial_type} runs past the payload")
        end
        values << decode_value(payload, body, serial_type, size.to_i32, encoding)
        body += size.to_i32
      end
      values
    end

    # Bytes of content for a serial type (fileformat2.html §2.1, table of
    # serial types).
    def self.content_size(serial_type : Int64, page_number : UInt32) : Int64
      case serial_type
      when 0, 8, 9 then 0_i64
      when 1       then 1_i64
      when 2       then 2_i64
      when 3       then 3_i64
      when 4       then 4_i64
      when 5       then 6_i64
      when 6, 7    then 8_i64
      when 10, 11  then corrupt(page_number, "serial type #{serial_type} is reserved")
      else
        corrupt(page_number, "serial type #{serial_type} is negative") if serial_type < 0
        (serial_type - 12) // 2
      end
    end

    private def self.decode_value(payload : Bytes, offset : Int32, serial_type : Int64, size : Int32, encoding : TextEncoding) : Value
      case serial_type
      when 0 then nil
      when 1 then payload[offset].to_i8!.to_i64
      when 2, 3, 4, 5, 6
        signed_integer(payload, offset, size)
      when 7
        bits = signed_integer(payload, offset, 8).to_u64!
        real = bits.unsafe_as(Float64)
        # SQLite reads a stored NaN as NULL (sqlite3VdbeSerialGet).
        real.nan? ? nil : real
      when 8 then 0_i64
      when 9 then 1_i64
      else
        content = payload[offset, size]
        serial_type.even? ? content.dup : decode_text(content, encoding)
      end
    end

    private def self.signed_integer(payload : Bytes, offset : Int32, size : Int32) : Int64
      value = payload.unsafe_fetch(offset).to_i8!.to_i64
      index = 1
      while index < size
        value = (value << 8) | payload.unsafe_fetch(offset + index)
        index += 1
      end
      value
    end

    # Text is stored in the database encoding; UTF-16 text is decoded to
    # UTF-8. An odd trailing byte of UTF-16 text is dropped, as SQLite does.
    def self.decode_text(content : Bytes, encoding : TextEncoding) : String
      return String.new(content) if encoding.utf8?
      units = Slice(UInt16).new(content.size // 2) do |index|
        first = content[index * 2].to_u16
        second = content[index * 2 + 1].to_u16
        encoding.utf16_le? ? (second << 8) | first : (first << 8) | second
      end
      String.from_utf16(units)
    end

    private def self.corrupt(page_number : UInt32, check : String) : NoReturn
      raise CorruptDatabase.new(check, page_number)
    end
  end
end
