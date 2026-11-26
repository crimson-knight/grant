module Grant::SQLiteEngine::Query
  # The columns of one FROM entry that the compiled query reads. Every
  # column reference the compiler builds marks its column here, so after
  # compiling, a table source decodes only these columns of each record
  # (C SQLite's OP_Column reads a column only when asked for it). A source
  # that needs whole rows calls `mark_all`.
  class ColumnUse
    @all = false
    # The marked columns: those below 64 as bits, any others in a set made
    # when the first of them is marked.
    @low_columns = 0_u64
    @high_columns : Set(Int32)? = nil
    @stored_mask : Array(Bool)? = nil
    @mask_ready = false
    # Replaced by the positions `stored_mask` finds; nothing changes it.
    NO_POSITIONS = [] of Int32
    @stored_positions = NO_POSITIONS

    def mark(column : Int32) : Nil
      return if marked?(column)
      @mask_ready = false
      if low_column?(column)
        @low_columns |= 1_u64 << column
      else
        high_columns = @high_columns ||= Set(Int32).new
        high_columns << column
      end
    end

    def mark_all : Nil
      @all = true
      @mask_ready = false
    end

    def all? : Bool
      @all
    end

    def includes?(column : Int32) : Bool
      @all || marked?(column)
    end

    private def marked?(column : Int32) : Bool
      if low_column?(column)
        return (@low_columns >> column) & 1_u64 == 1_u64
      end
      high_columns = @high_columns
      !high_columns.nil? && high_columns.includes?(column)
    end

    private def low_column?(column : Int32) : Bool
      column >= 0 && column < 64
    end

    # The stored record positions to decode for *table*.
    def stored_mask(table : TableInfo) : Array(Bool)
      mask = @stored_mask
      return mask if mask && @mask_ready
      mask = table.stored_mask_for(self)
      @stored_mask = mask
      @stored_positions = (0...mask.size).select { |position| mask[position] }
      @mask_ready = true
      mask
    end

    # The stored record positions to decode for *table*, in order.
    def stored_positions(table : TableInfo) : Array(Int32)
      stored_mask(table) unless @mask_ready
      @stored_positions
    end
  end

  # A record's header, read as far as the columns asked for (OP_Column
  # parses the header up to the column it needs and caches it), so the
  # values can be decoded one at a time in any order. Each entry read is
  # checked as `Record.decode` checks it.
  class RecordHeader
    @payload = Bytes.empty
    @page_number = 0_u32
    @header_end = 0
    @position = 0
    @body = 0
    @count = 0
    # Per entry read: its serial type, body offset and size, in buffers
    # that grow to the widest record seen and are reused for every row.
    @capacity = 16
    @serial_types = Pointer(Int64).malloc(16)
    @offsets = Pointer(Int32).malloc(16)
    @sizes = Pointer(Int32).malloc(16)

    def parse(payload : Bytes, page_number : UInt32) : Nil
      @payload = payload
      @page_number = page_number
      @count = 0
      header_size, length = Varint.decode(payload, 0)
      corrupt("record header varint is truncated") if length == 0
      if header_size < length || header_size > payload.size
        corrupt("record header size #{header_size} is outside #{length}..#{payload.size}")
      end
      @header_end = header_size.to_i32
      @position = length
      @body = @header_end
    end

    # True when the record holds a value at stored *position*.
    def has?(position : Int32) : Bool
      return true if position < @count
      read_through(position)
      @count > position
    end

    # The value at stored *position*, which `has?` found.
    def value(position : Int32, encoding : TextEncoding) : Value
      RecordColumns.value(@payload, @offsets[position], @serial_types[position],
        @sizes[position], encoding)
    end

    # The serial type at stored *position*, which `has?` found.
    def serial_type(position : Int32) : Int64
      @serial_types[position]
    end

    # The value at stored *position*, which `has?` found, when it is an
    # integer or a real other than NaN; nil otherwise (NULL, text, a blob,
    # or a NaN, which reads as NULL).
    def number(position : Int32) : (Int64 | Float64)?
      serial_type = @serial_types[position]
      return if serial_type == 0 || serial_type > 9
      offset = @offsets[position]
      case serial_type
      when 8 then 0_i64
      when 9 then 1_i64
      when 7
        real = RecordColumns.signed_integer(@payload, offset, 8).to_u64!.unsafe_as(Float64)
        real.nan? ? nil : real
      else
        RecordColumns.signed_integer(@payload, offset, @sizes[position])
      end
    end

    # The bytes of the value at stored *position*, which `has?` found,
    # when it is text; nil otherwise.
    def text_bytes(position : Int32) : Bytes?
      serial_type = @serial_types[position]
      return unless serial_type >= 13 && serial_type.odd?
      @payload[@offsets[position], @sizes[position]]
    end

    # Reads header entries until the one at *position* or the header end.
    # The loop keeps its state in locals and stores it once at the end.
    private def read_through(position : Int32) : Nil
      payload = @payload
      payload_size = payload.size
      header_end = @header_end
      cursor = @position
      body = @body
      count = @count
      wanted = position + 1
      while wanted > @capacity
        grow
      end
      serial_types = @serial_types
      offsets = @offsets
      sizes = @sizes
      # Body offsets only grow, so one check after the loop finds a value
      # running past the payload; `value_past_payload` then names the first.
      start = count
      while count < wanted && cursor < header_end
        byte = payload.unsafe_fetch(cursor)
        if byte < 0x80_u8
          serial_type = byte.to_i64
          cursor += 1
        else
          serial_type, used = Varint.decode(payload, cursor, header_end)
          corrupt("record serial type varint is truncated") if used == 0
          cursor += used
        end
        too_many_columns if count >= Record::MAX_RECORD_COLUMNS
        size = if serial_type >= 12
                 (serial_type - 12) >> 1
               elsif serial_type >= 0
                 RecordColumns::FIXED_SIZES.unsafe_fetch(serial_type)
               else
                 Record.content_size(serial_type, @page_number)
               end
        reserved_serial_type(serial_type) if size < 0
        size = Math.min(size, Int32::MAX.to_i64)
        serial_types[count] = serial_type
        offsets[count] = body
        sizes[count] = size.to_i32
        body = (body.to_i64 + size).clamp(0_i64, Int32::MAX.to_i64).to_i32
        count += 1
      end
      value_past_payload(start, count) if body > payload_size
      @position = cursor
      @body = body
      @count = count
    end

    @[NoInline]
    private def too_many_columns : NoReturn
      corrupt("record has more than #{Record::MAX_RECORD_COLUMNS} columns")
    end

    @[NoInline]
    private def reserved_serial_type(serial_type : Int64) : NoReturn
      corrupt("serial type #{serial_type} is reserved")
    end

    # Names the first of the columns *start*...*finish* whose value runs
    # past the payload.
    @[NoInline]
    private def value_past_payload(start : Int32, finish : Int32) : NoReturn
      (start...finish).each do |index|
        if @offsets[index].to_i64 + @sizes[index] > @payload.size
          corrupt("record value of serial type #{@serial_types[index]} runs past the payload")
        end
      end
      corrupt("record value runs past the payload")
    end

    @[NoInline]
    private def grow : Nil
      capacity = @capacity * 2
      @serial_types = @serial_types.realloc(capacity)
      @offsets = @offsets.realloc(capacity)
      @sizes = @sizes.realloc(capacity)
      @capacity = capacity
    end

    private def corrupt(check : String) : NoReturn
      raise CorruptDatabase.new(check, @page_number)
    end
  end

  # Decodes values of a record (fileformat2.html §2.1) for index searches
  # and whole index entries, checking each header entry as `Record.decode`
  # checks it.
  module RecordColumns
    # Compares the first values of the record in *payload* with *probe* the
    # way *order* sorts them (sqlite3VdbeRecordCompare), decoding only as
    # many values as it needs.
    def self.compare_prefix(payload : Bytes, encoding : TextEncoding, page_number : UInt32, probe : Array(Value),
                            order : IndexOrder) : Int32
      header_size, length = Varint.decode(payload, 0)
      corrupt(page_number, "record header varint is truncated") if length == 0
      if header_size < length || header_size > payload.size
        corrupt(page_number, "record header size #{header_size} is outside #{length}..#{payload.size}")
      end
      header_end = header_size.to_i32
      position = length
      body = header_end
      collations = order.collations
      descending = order.descending
      probe.each_with_index do |probe_value, index|
        stored = nil.as(Value)
        if position < header_end
          serial_type, used = Varint.decode(payload, position, header_end)
          corrupt(page_number, "record serial type varint is truncated") if used == 0
          position += used
          size = 0 <= serial_type < 12 ? FIXED_SIZES.unsafe_fetch(serial_type) : Record.content_size(serial_type, page_number)
          corrupt(page_number, "serial type #{serial_type} is reserved") if size < 0
          if body.to_i64 + size > payload.size
            corrupt(page_number, "record value of serial type #{serial_type} runs past the payload")
          end
          if probe_value.is_a?(Int64) && 0 < serial_type <= 9 && serial_type != 7
            # Two integers compare as integers whatever the collation.
            stored_integer = serial_type >= 8 ? serial_type - 8 : signed_integer(payload, body, size.to_i32)
            body += size.to_i32
            comparison = stored_integer <=> probe_value
            next if comparison == 0
            return descending[index]? ? -comparison : comparison
          end
          stored = value(payload, body, serial_type, size.to_i32, encoding)
          body += size.to_i32
        end
        comparison = ValueSemantics.compare(stored, probe_value, collations[index]? || Collation::Binary)
        return descending[index]? ? -comparison : comparison if comparison != 0
      end
      0
    end

    # The first value of the record in *payload* compared with *key* when
    # that value is an integer and the record is sound that far; nil
    # otherwise, for `compare_prefix` to decide (and report corruption).
    @[AlwaysInline]
    def self.compare_integer_key(payload : Bytes, key : Int64) : Int32?
      return if payload.size < 2
      header_size = payload.unsafe_fetch(0)
      serial_type = payload.unsafe_fetch(1)
      return unless 2 <= header_size < 0x80_u8 && 0 < serial_type <= 9 && serial_type != 7
      size = FIXED_SIZES.unsafe_fetch(serial_type)
      return if header_size.to_i64 + size > payload.size
      stored = serial_type >= 8 ? serial_type.to_i64 - 8 : signed_integer(payload, header_size.to_i32, size.to_i32)
      stored <=> key
    end

    # The first value of *payload* when the record header is one byte of
    # serial types and that value is an integer; nil otherwise (the reading
    # `compare_integer_key` makes).
    @[AlwaysInline]
    def self.leading_integer(payload : Bytes) : Int64?
      return if payload.size < 2
      header_size = payload.unsafe_fetch(0)
      serial_type = payload.unsafe_fetch(1)
      return unless 2 <= header_size < 0x80_u8 && 0 < serial_type <= 9 && serial_type != 7
      return serial_type.to_i64 - 8 if serial_type >= 8
      size = FIXED_SIZES.unsafe_fetch(serial_type)
      return if header_size.to_i64 + size > payload.size
      signed_integer(payload, header_size.to_i32, size.to_i32)
    end

    # The two values of a record of exactly two integers (an index entry of
    # one integer key and the rowid), read as `decode_into` reads them; nil
    # for any other record.
    @[AlwaysInline]
    def self.integer_pair(payload : Bytes) : {Int64, Int64}?
      return if payload.size < 3 || payload.unsafe_fetch(0) != 3
      first_type = payload.unsafe_fetch(1)
      second_type = payload.unsafe_fetch(2)
      return unless 0 < first_type <= 9 && first_type != 7 && 0 < second_type <= 9 && second_type != 7
      first_size = FIXED_SIZES.unsafe_fetch(first_type).to_i32
      second_size = FIXED_SIZES.unsafe_fetch(second_type).to_i32
      return if 3 + first_size + second_size > payload.size
      first = first_type >= 8 ? first_type.to_i64 - 8 : signed_integer(payload, 3, first_size)
      second = second_type >= 8 ? second_type.to_i64 - 8 : signed_integer(payload, 3 + first_size, second_size)
      {first, second}
    end

    # Decodes every value of *payload* into *into*, replacing what it held.
    def self.decode_into(payload : Bytes, encoding : TextEncoding, page_number : UInt32, into : Array(Value)) : Array(Value)
      # Values overwrite the array in place; a longer old record is cut
      # back at the end.
      count = 0
      header_size, length = Varint.decode(payload, 0)
      corrupt(page_number, "record header varint is truncated") if length == 0
      if header_size < length || header_size > payload.size
        corrupt(page_number, "record header size #{header_size} is outside #{length}..#{payload.size}")
      end
      header_end = header_size.to_i32
      position = length
      body = header_end
      while position < header_end
        serial_type, used = Varint.decode(payload, position, header_end)
        corrupt(page_number, "record serial type varint is truncated") if used == 0
        position += used
        corrupt(page_number, "record has more than #{Record::MAX_RECORD_COLUMNS} columns") if count >= Record::MAX_RECORD_COLUMNS
        size = 0 <= serial_type < 12 ? FIXED_SIZES.unsafe_fetch(serial_type) : Record.content_size(serial_type, page_number)
        corrupt(page_number, "serial type #{serial_type} is reserved") if size < 0
        if body.to_i64 + size > payload.size
          corrupt(page_number, "record value of serial type #{serial_type} runs past the payload")
        end
        decoded = value(payload, body, serial_type, size.to_i32, encoding)
        if count < into.size
          into.unsafe_put(count, decoded)
        else
          into << decoded
        end
        count += 1
        body += size.to_i32
      end
      (into.size - count).times { into.pop }
      into
    end

    # Content sizes of serial types 0 to 11; -1 marks the reserved 10 and 11.
    FIXED_SIZES = StaticArray[0_i64, 1_i64, 2_i64, 3_i64, 4_i64, 6_i64, 8_i64, 8_i64, 0_i64, 0_i64, -1_i64, -1_i64]

    # One value, as sqlite3VdbeSerialGet reads it.
    def self.value(payload : Bytes, offset : Int32, serial_type : Int64, size : Int32, encoding : TextEncoding) : Value
      case serial_type
      when 0 then nil
      when 1 then payload.unsafe_fetch(offset).to_i8!.to_i64
      when 2, 3, 4, 5, 6
        signed_integer(payload, offset, size)
      when 7
        real = signed_integer(payload, offset, 8).to_u64!.unsafe_as(Float64)
        # SQLite reads a stored NaN as NULL.
        real.nan? ? nil : real
      when 8 then 0_i64
      when 9 then 1_i64
      else
        content = payload[offset, size]
        serial_type.even? ? content.dup : Record.decode_text(content, encoding)
      end
    end

    # The big-endian two's-complement integer of *size* bytes at *offset*.
    def self.signed_integer(payload : Bytes, offset : Int32, size : Int32) : Int64
      value = payload.unsafe_fetch(offset).to_i8!.to_i64
      return value if size == 1
      value = (value << 8) | payload.unsafe_fetch(offset + 1)
      return value if size == 2
      index = 2
      while index < size
        value = (value << 8) | payload.unsafe_fetch(offset + index)
        index += 1
      end
      value
    end

    private def self.corrupt(page_number : UInt32, check : String) : NoReturn
      raise CorruptDatabase.new(check, page_number)
    end
  end
end
