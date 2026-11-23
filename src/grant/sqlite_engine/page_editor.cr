module Grant::SQLiteEngine
  # Changes the cells of one b-tree page in place (fileformat2.html §1.6):
  # the cell pointer array, the cell content area growing down from the end
  # of the page, freeblocks (a chain of free spans of 4 bytes or more) and
  # fragmented bytes (free spans of 1 to 3 bytes). Ported from btree.c's
  # allocateSpace, pageFindSlot, freeSpace and defragmentPage.
  struct PageEditor
    # btree.c refuses to add fragments past this count and defragments.
    MAX_FRAGMENTED_BYTES = 60

    # The smallest space a cell takes (btree.c pads shorter cells to 4).
    MIN_CELL_SPACE = 4

    getter data : Bytes
    getter number : UInt32
    getter usable_size : Int32
    getter header_offset : Int32

    def initialize(@data : Bytes, @number : UInt32, @usable_size : Int32)
      @header_offset = @number == 1 ? DatabaseHeader::SIZE : 0
    end

    # Bytes the header of a page of *page_type* takes.
    def self.header_size(page_type : PageType) : Int32
      page_type.interior? ? 12 : 8
    end

    # Content bytes and pointers a page can hold.
    def self.capacity(page_number : UInt32, page_type : PageType, usable_size : Int32) : Int32
      usable_size - (page_number == 1 ? DatabaseHeader::SIZE : 0) - header_size(page_type)
    end

    # Bytes a cell of *content_size* bytes takes on a page, with its pointer.
    def self.cost(content_size : Int32) : Int32
      Math.max(MIN_CELL_SPACE, content_size) + 2
    end

    # fileformat2.html §1.6: bytes of a payload of *size* kept on the page.
    def self.local_payload_size(usable_size : Int32, size : Int64, table_leaf : Bool) : Int32
      usable = usable_size.to_i64
      max_local = table_leaf ? usable - 35 : ((usable - 12) * 64 // 255) - 23
      return size.to_i32 if size <= max_local
      min_local = ((usable - 12) * 32 // 255) - 23
      spill_local = min_local + ((size - min_local) % (usable - 4))
      (spill_local <= max_local ? spill_local : min_local).to_i32
    end

    # Content bytes of a cell starting at *offset* of *bytes*: its header
    # varints, local payload and overflow pointer, without padding.
    def self.cell_content_size(bytes : Bytes, offset : Int32, page_type : PageType, usable_size : Int32, page_number : UInt32) : Int32
      limit = Math.min(bytes.size, usable_size)
      if page_type.interior_table?
        _key, length = Varint.decode(bytes, offset + 4, limit)
        raise CorruptDatabase.new("cell varint runs past the usable size", page_number) if length == 0
        return 4 + length
      end
      start = page_type.interior_index? ? offset + 4 : offset
      size, size_length = Varint.decode(bytes, start, limit)
      raise CorruptDatabase.new("cell varint runs past the usable size", page_number) if size_length == 0
      raise CorruptDatabase.new("cell payload size #{size} is out of range", page_number) if size < 0 || size > Int32::MAX
      header = start - offset + size_length
      if page_type.leaf_table?
        _rowid, rowid_length = Varint.decode(bytes, offset + header, limit)
        raise CorruptDatabase.new("cell varint runs past the usable size", page_number) if rowid_length == 0
        header += rowid_length
      end
      local = local_payload_size(usable_size, size, page_type.leaf_table?)
      header + local + (local < size ? 4 : 0)
    end

    def page_type : PageType
      type = PageType.from_value?(@data[@header_offset])
      raise CorruptDatabase.new("page type #{@data[@header_offset]} is not 2, 5, 10 or 13", @number) unless type
      type
    end

    # Writes an empty page header of *page_type*.
    def initialize_page(page_type : PageType) : Nil
      header_size = PageEditor.header_size(page_type)
      (@data + @header_offset).to_unsafe.clear(header_size)
      @data[@header_offset] = page_type.value
      set_content_start(@usable_size)
    end

    def cell_count : Int32
      u16(@header_offset + 3)
    end

    def right_child : UInt32
      u32(@header_offset + 8)
    end

    def right_child=(page_number : UInt32) : UInt32
      put_u32(@header_offset + 8, page_number)
      page_number
    end

    def cell_offset(index : Int32) : Int32
      offset = u16(pointer_array_offset + index * 2)
      raise CorruptDatabase.new("cell #{index} pointer #{offset} is outside the page", @number) if offset < pointer_array_end || offset >= @usable_size
      offset
    end

    # The content bytes of cell *index* (a view into the page).
    def cell(index : Int32) : Bytes
      offset = cell_offset(index)
      size = PageEditor.cell_content_size(@data, offset, page_type, @usable_size, @number)
      raise CorruptDatabase.new("cell #{index} runs past the usable size", @number) if offset + size > @usable_size
      @data[offset, size]
    end

    # Copies of every cell, in order: slices of one copy of the page, so a
    # page of many small cells costs one allocation (as balance_nonroot
    # copies cells into one scratch buffer).
    def list_of_cells : Array(Bytes)
      type = page_type
      count = cell_count
      pointers = @header_offset + PageEditor.header_size(type)
      pointers_end = pointers + count * 2
      raise CorruptDatabase.new("cell pointer array runs past the usable size", @number) if pointers_end > Math.min(@usable_size, @data.size)
      copy = @data.dup
      data = @data
      # A leaf index cell whose payload size fits one varint byte and stays
      # on the page is that byte and the payload (the common case).
      index_leaf = type.leaf_index?
      max_local = ((@usable_size - 12) * 64 // 255) - 23
      Array(Bytes).new(count) do |index|
        at = pointers + index * 2
        offset = (data.unsafe_fetch(at).to_i32 << 8) | data.unsafe_fetch(at + 1)
        if offset < pointers_end || offset >= @usable_size
          raise CorruptDatabase.new("cell #{index} pointer #{offset} is outside the page", @number)
        end
        first = data.unsafe_fetch(offset)
        size = if index_leaf && first < 0x80 && first <= max_local
                 1 + first.to_i32
               else
                 PageEditor.cell_content_size(data, offset, type, @usable_size, @number)
               end
        raise CorruptDatabase.new("cell #{index} runs past the usable size", @number) if offset + size > @usable_size
        copy[offset, size]
      end
    end

    # Free bytes: the gap between the pointer array and the content area,
    # the freeblocks and the fragments (btree.c's nFree).
    def free_space : Int32
      total = content_start - pointer_array_end + @data[@header_offset + 7]
      block = u16(@header_offset + 1)
      steps = 0
      while block != 0
        raise CorruptDatabase.new("freeblock #{block} is outside the page", @number) if block + 4 > @usable_size
        steps += 1
        raise CorruptDatabase.new("freeblock chain does not end", @number) if steps > @usable_size // 4
        total += u16(block + 2)
        following = u16(block)
        raise CorruptDatabase.new("freeblocks are out of order", @number) if following != 0 && following <= block
        block = following
      end
      total
    end

    # Inserts *content* as cell *index*. Returns false, changing nothing,
    # when the page lacks the room.
    def insert_cell(index : Int32, content : Bytes) : Bool
      space = Math.max(MIN_CELL_SPACE, content.size)
      return false if free_space < space + 2
      offset = allocate_space(space)
      (@data + offset).copy_from(content.to_unsafe, content.size)
      (@data + offset + content.size).to_unsafe.clear(space - content.size) if space > content.size
      count = cell_count
      pointers = pointer_array_offset
      (@data + pointers + index * 2 + 2).move_from((@data + pointers + index * 2).to_unsafe, (count - index) * 2) if index < count
      put_u16(pointers + index * 2, offset)
      put_u16(@header_offset + 3, count + 1)
      true
    end

    # Removes cell *index*, returning its space to the page.
    def remove_cell(index : Int32) : Nil
      offset = cell_offset(index)
      space = Math.max(MIN_CELL_SPACE, PageEditor.cell_content_size(@data, offset, page_type, @usable_size, @number))
      count = cell_count
      pointers = pointer_array_offset
      (@data + pointers + index * 2).move_from((@data + pointers + index * 2 + 2).to_unsafe, (count - index - 1) * 2) if index < count - 1
      put_u16(@header_offset + 3, count - 1)
      if count == 1
        # dropCell: an emptied page starts over with one free gap.
        put_u16(@header_offset + 1, 0)
        @data[@header_offset + 7] = 0_u8
        set_content_start(@usable_size)
        return
      end
      free_space_at(offset, space)
    end

    # Rewrites the page holding *list_of_cells* in order, packed at the end
    # of the page with no freeblocks.
    def rebuild(page_type : PageType, list_of_cells : Indexable(Bytes), right_child : UInt32) : Nil
      initialize_page(page_type)
      self.right_child = right_child if page_type.interior?
      top = @usable_size
      pointers = pointer_array_offset
      floor = pointers + list_of_cells.size * 2
      raise Error.new("cells do not fit page #{@number}") if @usable_size > @data.size || floor > @usable_size
      page = @data.to_unsafe
      list_of_cells.each_with_index do |content, index|
        size = content.size
        space = size < MIN_CELL_SPACE ? MIN_CELL_SPACE : size
        top -= space
        # Checked before each write, so the unchecked copies below stay
        # between the pointer array and the end of the usable area.
        raise Error.new("cells do not fit page #{@number}") if top < floor
        (page + top).copy_from(content.to_unsafe, size)
        (page + top + size).clear(space - size) if space > size
        page[pointers + index * 2] = (top >> 8).to_u8!
        page[pointers + index * 2 + 1] = top.to_u8!
      end
      put_u16(@header_offset + 3, list_of_cells.size)
      set_content_start(top)
      (@data + pointers + list_of_cells.size * 2).to_unsafe.clear(top - pointers - list_of_cells.size * 2)
    end

    # Packs every cell at the end of the page (defragmentPage).
    def defragment : Nil
      rebuild(page_type, list_of_cells, page_type.interior? ? right_child : 0_u32)
    end

    private def pointer_array_offset : Int32
      @header_offset + PageEditor.header_size(page_type)
    end

    private def pointer_array_end : Int32
      pointer_array_offset + cell_count * 2
    end

    private def content_start : Int32
      start = u16(@header_offset + 5)
      start == 0 ? 65_536 : start
    end

    private def set_content_start(offset : Int32) : Nil
      put_u16(@header_offset + 5, offset == 65_536 ? 0 : offset)
    end

    # allocateSpace: a freeblock that fits when the gap still has room for
    # the new pointer, otherwise the top of the gap, defragmenting first
    # when the gap is too small.
    private def allocate_space(space : Int32) : Int32
      gap = pointer_array_end
      top = content_start
      if u16(@header_offset + 1) != 0 && gap + 2 <= top
        if slot = find_slot(space)
          return slot
        end
      end
      if gap + 2 + space > top
        defragment
        top = content_start
      end
      top -= space
      set_content_start(top)
      top
    end

    # pageFindSlot: the first freeblock of at least *space* bytes. A
    # leftover under 4 bytes becomes fragments; a larger one stays a
    # freeblock and the cell takes its end.
    private def find_slot(space : Int32) : Int32?
      previous = @header_offset + 1
      block = u16(previous)
      while block != 0
        size = u16(block + 2)
        leftover = size - space
        if leftover >= 0
          if leftover < 4
            return if @data[@header_offset + 7] > MAX_FRAGMENTED_BYTES - 3
            put_u16(previous, u16(block))
            @data[@header_offset + 7] += leftover.to_u8
            return block
          end
          put_u16(block + 2, leftover)
          return block + leftover
        end
        previous = block
        block = u16(block)
      end
      nil
    end

    # freeSpace: returns *space* bytes at *start* to the freeblock chain,
    # merging with neighbors and with fragments between them, or to the gap
    # when the span begins the content area.
    private def free_space_at(start : Int32, space : Int32) : Nil
      finish = start + space
      pointer = @header_offset + 1
      following = u16(pointer)
      while following != 0 && following < start
        pointer = following
        following = u16(following)
      end
      fragments = 0
      if following != 0 && finish + 3 >= following
        fragments = following - finish
        finish = following + u16(following + 2)
        following = u16(following)
      end
      if pointer > @header_offset + 1
        previous_end = pointer + u16(pointer + 2)
        if previous_end + 3 >= start
          fragments += start - previous_end
          start = pointer
        end
      end
      @data[@header_offset + 7] = (@data[@header_offset + 7].to_i32 - fragments).clamp(0, 255).to_u8
      # Compared with the raw field, as freeSpace does (0 on a 65,536-byte
      # page, where the span always becomes a freeblock).
      if start <= u16(@header_offset + 5)
        put_u16(@header_offset + 1, following)
        set_content_start(finish)
      else
        put_u16(pointer, start)
        put_u16(start, following)
        put_u16(start + 2, finish - start)
      end
    end

    private def u16(offset : Int32) : Int32
      (@data[offset].to_i32 << 8) | @data[offset + 1]
    end

    private def put_u16(offset : Int32, value : Int32) : Nil
      @data[offset] = (value >> 8).to_u8!
      @data[offset + 1] = value.to_u8!
    end

    private def u32(offset : Int32) : UInt32
      (@data[offset].to_u32 << 24) | (@data[offset + 1].to_u32 << 16) | (@data[offset + 2].to_u32 << 8) | @data[offset + 3]
    end

    private def put_u32(offset : Int32, value : UInt32) : Nil
      @data[offset] = (value >> 24).to_u8!
      @data[offset + 1] = (value >> 16).to_u8!
      @data[offset + 2] = (value >> 8).to_u8!
      @data[offset + 3] = value.to_u8!
    end
  end
end
