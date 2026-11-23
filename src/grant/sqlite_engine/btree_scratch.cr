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

    alias Mark = {Int32, Int32}

    @list_of_pages = [] of Bytes
    @list_of_cell_lists = [] of Array(Bytes)
    @pages_in_use = 0
    @cell_lists_in_use = 0

    def mark : Mark
      {@pages_in_use, @cell_lists_in_use}
    end

    # Returns everything borrowed since *mark*.
    def release(mark : Mark) : Nil
      @pages_in_use, @cell_lists_in_use = mark
    end

    # A buffer of *size* bytes, its contents undefined.
    def page(size : Int32) : Bytes
      index = @pages_in_use
      @pages_in_use += 1
      if index < @list_of_pages.size
        buffer = @list_of_pages[index]
        return buffer if buffer.size == size
        return @list_of_pages[index] = Bytes.new(size)
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
  end
end
