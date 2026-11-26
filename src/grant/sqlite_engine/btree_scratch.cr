module Grant::SQLiteEngine
  # The page copies and cell lists a b-tree change borrows while it
  # balances, kept for the next change instead of allocated each time (as
  # btree.c's balance_nonroot works in one scratch space). A change takes
  # what it needs after `mark`, and `release` hands it all back when the
  # change ends, so nothing borrowed may outlive the change.
  class BTreeScratch
    # Buffers kept between changes; a change that borrows more (freeing a
    # whole tree) gets the rest without keeping them.
    KEPT_LIMIT = 16

    alias Mark = {Int32, Int32, Int32}

    @list_of_pages = [] of Bytes
    @list_of_cell_lists = [] of Array(Bytes)
    @pages_in_use = 0
    @cell_lists_in_use = 0
    @list_of_paths = [] of Array({UInt32, Int32})
    @paths_in_use = 0

    def mark : Mark
      {@pages_in_use, @cell_lists_in_use, @paths_in_use}
    end

    # Returns everything borrowed since *mark*.
    def release(mark : Mark) : Nil
      @pages_in_use, @cell_lists_in_use, @paths_in_use = mark
    end

    # The buffer the entries of index b-trees are encoded into.
    getter record_buffer = RecordEncoder::EncodeBuffer.new

    # *size* bytes (a page copy or a cell), their contents undefined.
    def page(size : Int32) : Bytes
      index = @pages_in_use
      @pages_in_use += 1
      if index < @list_of_pages.size
        buffer = @list_of_pages[index]
        return buffer[0, size] if buffer.size >= size
        buffer = @list_of_pages[index] = Bytes.new(size)
        return buffer
      end
      buffer = Bytes.new(size)
      @list_of_pages << buffer if index < KEPT_LIMIT
      buffer
    end

    # An empty cell list.
    def cell_list : Array(Bytes)
      index = @cell_lists_in_use
      @cell_lists_in_use += 1
      if index < @list_of_cell_lists.size
        list = @list_of_cell_lists[index]
        list.clear
        return list
      end
      list = [] of Bytes
      @list_of_cell_lists << list if index < KEPT_LIMIT
      list
    end

    # An empty path from a root to a leaf: the pages a seek passed and the
    # child taken at each.
    def path : Array({UInt32, Int32})
      index = @paths_in_use
      @paths_in_use += 1
      if index < @list_of_paths.size
        list = @list_of_paths[index]
        list.clear
        return list
      end
      list = [] of {UInt32, Int32}
      @list_of_paths << list if index < KEPT_LIMIT
      list
    end
  end
end
