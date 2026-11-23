module Grant::SQLiteEngine
  # The four b-tree page kinds (fileformat2.html §1.6).
  enum PageType : UInt8
    InteriorIndex =  2
    InteriorTable =  5
    LeafIndex     = 10
    LeafTable     = 13

    def interior? : Bool
      interior_index? || interior_table?
    end

    def leaf? : Bool
      !interior?
    end

    def table? : Bool
      interior_table? || leaf_table?
    end
  end

  # Where a cell's payload lives: the bytes on the page and, when it spills,
  # the first overflow page.
  struct PayloadLocation
    getter page_number : UInt32
    getter local_offset : Int32
    getter local_size : Int32
    getter total_size : Int32
    getter first_overflow_page : UInt32

    def initialize(@page_number : UInt32, @local_offset : Int32, @local_size : Int32, @total_size : Int32, @first_overflow_page : UInt32)
    end

    def spills? : Bool
      @first_overflow_page != 0
    end
  end

  # A parsed b-tree page: its header and cell pointer array, checked against
  # the page bounds. Cells are decoded on demand.
  struct BTreePage
    getter number : UInt32
    getter data : Bytes
    getter page_type : PageType
    getter cell_count : Int32
    getter right_child : UInt32
    getter usable_size : Int32

    @header_offset : Int32
    @pointer_array_offset : Int32
    @pointer_array_end : Int32
    @page_count : UInt32

    def self.read(pager : Pager, number : UInt32) : BTreePage
      new(number, pager.read_page(number), pager.usable_size, pager.page_count)
    end

    def initialize(@number : UInt32, @data : Bytes, @usable_size : Int32, @page_count : UInt32)
      @header_offset = @number == 1 ? DatabaseHeader::SIZE : 0
      corrupt("page header runs past the usable size") if @header_offset + 8 > @usable_size
      type = PageType.from_value?(@data[@header_offset])
      corrupt("page type #{@data[@header_offset]} is not 2, 5, 10 or 13") unless type
      @page_type = type
      header_size = type.interior? ? 12 : 8
      corrupt("page header runs past the usable size") if @header_offset + header_size > @usable_size
      @cell_count = u16(@header_offset + 3)
      @pointer_array_offset = @header_offset + header_size
      @pointer_array_end = @pointer_array_offset + @cell_count * 2
      corrupt("#{@cell_count} cell pointers run past the usable size") if @pointer_array_end > @usable_size
      @right_child = type.interior? ? u32(@header_offset + 8) : 0_u32
      check_child(@right_child) if type.interior?
    end

    # Offset of cell *index* on the page, checked to lie after the pointer
    # array and inside the usable size.
    def cell_offset(index : Int32) : Int32
      # The pointer array was checked to lie inside the page.
      pointer = if 0 <= index < @cell_count
                  at = @pointer_array_offset + index * 2
                  (@data.unsafe_fetch(at).to_i32 << 8) | @data.unsafe_fetch(at + 1)
                else
                  u16(@pointer_array_offset + index * 2)
                end
      unless pointer >= @pointer_array_end && pointer < @usable_size
        corrupt("cell #{index} pointer #{pointer} is outside #{@pointer_array_end}...#{@usable_size}")
      end
      pointer
    end

    # Left child page number of interior cell *index*.
    def left_child(index : Int32) : UInt32
      offset = cell_offset(index)
      corrupt("cell #{index} child pointer runs past the usable size") if offset + 4 > @usable_size
      child = u32(offset)
      check_child(child)
      child
    end

    # Integer key (rowid) of a table cell, leaf or interior.
    def rowid(index : Int32) : Int64
      offset = cell_offset(index)
      if @page_type.interior_table?
        key, _key_length = varint(offset + 4, index)
        return key
      end
      _size, size_length = varint(offset, index)
      key, _key_length = varint(offset + size_length, index)
      key
    end

    # Rowid and payload location of a leaf table cell, read in one pass.
    def table_leaf_cell(index : Int32) : {Int64, PayloadLocation}
      offset = cell_offset(index)
      size, size_length = varint(offset, index)
      key, key_length = varint(offset + size_length, index)
      {key, payload_location(index, offset + size_length + key_length, size, true)}
    end

    # The rowid and payload of leaf table cell *index* when the payload lies
    # wholly on the page (no overflow), as `table_leaf_cell` and
    # `PayloadReader.read` would give them; nil otherwise, and for a cell
    # those checks would reject, so the caller takes that path and its
    # error.
    def local_table_leaf_cell(index : Int32) : {Int64, Bytes}?
      offset = cell_offset(index)
      size, size_length = varint(offset, index)
      key, key_length = varint(offset + size_length, index)
      start = offset + size_length + key_length
      return unless 0 <= size <= @usable_size - 35 && start + size <= @usable_size
      {key, Bytes.new(@data.to_unsafe + start, size.to_i32, read_only: @data.read_only?)}
    end

    # The payload of index cell *index* (leaf or interior) when it lies
    # wholly on the page, as `payload` and `PayloadReader.read` would give
    # it; nil otherwise, and for a cell those checks would reject.
    def local_index_payload(index : Int32) : Bytes?
      offset = cell_offset(index)
      if @page_type.interior_index?
        return if offset + 4 > @usable_size
        offset += 4
      elsif !@page_type.leaf_index?
        return
      end
      size, size_length = varint(offset, index)
      start = offset + size_length
      max_local = ((@usable_size - 12) * 64 // 255) - 23
      return unless 0 <= size <= max_local && start + size <= @usable_size
      Bytes.new(@data.to_unsafe + start, size.to_i32, read_only: @data.read_only?)
    end

    # Payload location of a leaf table cell, a leaf index cell or an interior
    # index cell. Interior table cells have no payload.
    def payload(index : Int32) : PayloadLocation
      offset = cell_offset(index)
      case @page_type
      when .leaf_table?
        size, size_length = varint(offset, index)
        _key, key_length = varint(offset + size_length, index)
        payload_location(index, offset + size_length + key_length, size, true)
      when .leaf_index?
        size, size_length = varint(offset, index)
        payload_location(index, offset + size_length, size, false)
      when .interior_index?
        corrupt("cell #{index} child pointer runs past the usable size") if offset + 4 > @usable_size
        size, size_length = varint(offset + 4, index)
        payload_location(index, offset + 4 + size_length, size, false)
      else
        corrupt("interior table cells carry no payload")
      end
    end

    def corrupt(check : String) : NoReturn
      raise CorruptDatabase.new(check, @number)
    end

    # fileformat2.html §1.6, the payload formulas: X is the most a cell keeps
    # on the page, M the least, and K the size that makes the overflow fill
    # whole pages.
    private def payload_location(index : Int32, start : Int32, size : Int64, table_leaf : Bool) : PayloadLocation
      usable = @usable_size.to_i64
      corrupt("cell #{index} payload size #{size} is negative") if size < 0
      max_payload = (@page_count.to_i64 * (usable - 4)) + usable
      corrupt("cell #{index} payload size #{size} exceeds what the file can hold") if size > max_payload || size > Int32::MAX
      local = local_payload_size(size, table_leaf)
      spills = local < size
      local_end = start.to_i64 + local + (spills ? 4 : 0)
      corrupt("cell #{index} payload runs past the usable size") if local_end > usable
      overflow = spills ? u32(start + local.to_i32) : 0_u32
      if spills && (overflow == 0 || overflow > @page_count)
        corrupt("cell #{index} first overflow page #{overflow} is outside 1..#{@page_count}")
      end
      PayloadLocation.new(@number, start, local.to_i32, size.to_i32, overflow)
    end

    private def local_payload_size(size : Int64, table_leaf : Bool) : Int64
      usable = @usable_size.to_i64
      max_local = table_leaf ? usable - 35 : ((usable - 12) * 64 // 255) - 23
      return size if size <= max_local
      min_local = ((usable - 12) * 32 // 255) - 23
      spill_local = min_local + ((size - min_local) % (usable - 4))
      spill_local <= max_local ? spill_local : min_local
    end

    private def check_child(child : UInt32) : Nil
      corrupt("child page #{child} is outside 1..#{@page_count}") if child == 0 || child > @page_count
    end

    private def varint(offset : Int32, index : Int32) : {Int64, Int32}
      value, length = Varint.decode(@data, offset, @usable_size)
      corrupt("cell #{index} varint runs past the usable size") if length == 0
      {value, length}
    end

    private def u16(offset : Int32) : Int32
      (@data[offset].to_i32 << 8) | @data[offset + 1]
    end

    private def u32(offset : Int32) : UInt32
      (@data[offset].to_u32 << 24) | (@data[offset + 1].to_u32 << 16) | (@data[offset + 2].to_u32 << 8) | @data[offset + 3]
    end
  end
end
