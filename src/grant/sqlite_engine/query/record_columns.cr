module Grant::SQLiteEngine::Query
  # The columns of one FROM entry that the compiled query reads. Every
  # column reference the compiler builds marks its column here, so after
  # compiling, a table source decodes only these columns of each record
  # (C SQLite's OP_Column reads a column only when asked for it). A source
  # that needs whole rows calls `mark_all`.
  class ColumnUse
    @all = false
    @columns = Set(Int32).new
    @stored_mask : Array(Bool)? = nil
    @mask_ready = false
    @stored_positions = [] of Int32

    def mark(column : Int32) : Nil
      @mask_ready = false unless @columns.includes?(column)
      @columns << column
    end

    def mark_all : Nil
      @all = true
      @mask_ready = false
    end

    def all? : Bool
      @all
    end

    def includes?(column : Int32) : Bool
      @all || @columns.includes?(column)
    end

    # The stored record positions to decode for *table*.
    def stored_mask(table : TableInfo) : Array(Bool)
      mask = @stored_mask
      return mask if mask && @mask_ready
      mask = @all ? table.stored_mask_for(nil) : table.stored_mask_for(@columns)
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
    @list_of_serial_types = [] of Int64
    @list_of_offsets = [] of Int32
    @list_of_sizes = [] of Int32

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
      while @count <= position && @position < @header_end
        read_entry
      end
      @count > position
    end

    # The value at stored *position*, which `has?` found.
    def value(position : Int32, encoding : TextEncoding) : Value
      RecordColumns.value(@payload, @list_of_offsets.unsafe_fetch(position), @list_of_serial_types.unsafe_fetch(position),
        @list_of_sizes.unsafe_fetch(position), encoding)
    end

    # The bytes of the value at stored *position*, which `has?` found,
    # when it is text; nil otherwise.
    def text_bytes(position : Int32) : Bytes?
      serial_type = @list_of_serial_types.unsafe_fetch(position)
      return unless serial_type >= 13 && serial_type.odd?
      @payload[@list_of_offsets.unsafe_fetch(position), @list_of_sizes.unsafe_fetch(position)]
    end

    private def read_entry : Nil
      payload = @payload
      byte = payload.unsafe_fetch(@position)
      if byte < 0x80_u8
        serial_type = byte.to_i64
        @position += 1
      else
        serial_type, used = Varint.decode(payload, @position, @header_end)
        corrupt("record serial type varint is truncated") if used == 0
        @position += used
      end
      corrupt("record has more than #{Record::MAX_RECORD_COLUMNS} columns") if @count >= Record::MAX_RECORD_COLUMNS
      size = if serial_type >= 12
               (serial_type - 12) >> 1
             elsif serial_type >= 0
               RecordColumns::FIXED_SIZES.unsafe_fetch(serial_type)
             else
               Record.content_size(serial_type, @page_number)
             end
      corrupt("serial type #{serial_type} is reserved") if size < 0
      if @body.to_i64 + size > payload.size
        corrupt("record value of serial type #{serial_type} runs past the payload")
      end
      store(@list_of_serial_types, @count, serial_type)
      store(@list_of_offsets, @count, @body)
      store(@list_of_sizes, @count, size.to_i32)
      @body += size.to_i32
      @count += 1
    end

    private def store(list : Array(T), index : Int32, item : T) : Nil forall T
      if index < list.size
        list.unsafe_put(index, item)
      else
        list << item
      end
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
          stored = value(payload, body, serial_type, size.to_i32, encoding)
          body += size.to_i32
        end
        comparison = ValueSemantics.compare(stored, probe_value, collations[index]? || Collation::Binary)
        return descending[index]? ? -comparison : comparison if comparison != 0
      end
      0
    end

    # Decodes every value of *payload* into *into*, replacing what it held.
    def self.decode_into(payload : Bytes, encoding : TextEncoding, page_number : UInt32, into : Array(Value)) : Array(Value)
      into.clear
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
        corrupt(page_number, "record has more than #{Record::MAX_RECORD_COLUMNS} columns") if into.size >= Record::MAX_RECORD_COLUMNS
        size = 0 <= serial_type < 12 ? FIXED_SIZES.unsafe_fetch(serial_type) : Record.content_size(serial_type, page_number)
        corrupt(page_number, "serial type #{serial_type} is reserved") if size < 0
        if body.to_i64 + size > payload.size
          corrupt(page_number, "record value of serial type #{serial_type} runs past the payload")
        end
        into << value(payload, body, serial_type, size.to_i32, encoding)
        body += size.to_i32
      end
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

    private def self.signed_integer(payload : Bytes, offset : Int32, size : Int32) : Int64
      value = payload.unsafe_fetch(offset).to_i8!.to_i64
      index = 1
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
