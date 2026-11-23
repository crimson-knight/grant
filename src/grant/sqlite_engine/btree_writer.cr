module Grant::SQLiteEngine
  # A b-tree page held in memory while it is rebalanced: its cells (content
  # bytes, without padding) and, for interior pages, the right child.
  class TreeNode
    property page_number : UInt32
    property page_type : PageType
    property list_of_cells : Array(Bytes)
    property right_child : UInt32

    def initialize(@page_number : UInt32, @page_type : PageType, @list_of_cells : Array(Bytes), @right_child : UInt32)
    end
  end

  # Inserts and deletes cells of table and index b-trees
  # (fileformat2.html §1.6), allocating and releasing overflow chains, and
  # keeps every page within its size by balancing: a full page splits, its
  # contents spread over up to three siblings (btree.c's balance_nonroot is
  # the reference, not byte for byte), a page left under a third full merges
  # with its siblings, a full root moves its contents into a new child
  # (balance_deeper) and an empty interior root takes its only child's
  # contents back (the end of balance_nonroot).
  class BTreeWriter
    # A path entry: a page and the child taken from it (a cell index, or
    # the cell count for the right child).
    alias PathEntry = {UInt32, Int32}

    def initialize(@pager : Pager, @encoding : TextEncoding, @schema_format : UInt32 = 4_u32)
    end

    private def usable : Int32
      @pager.usable_size
    end

    # --- Trees ----------------------------------------------------------

    # A new empty b-tree: a table leaf or an index leaf page.
    def create_tree(table : Bool) : UInt32
      root = @pager.allocate_page
      write_node(TreeNode.new(root, table ? PageType::LeafTable : PageType::LeafIndex, [] of Bytes, 0_u32))
      root
    end

    # Releases every page of the b-tree rooted at *root*, its overflow
    # chains, and the root itself, to the freelist.
    def free_tree(root : UInt32) : Nil
      stack = [{root, 0}]
      seen = Set(UInt32).new
      while entry = stack.pop?
        page_number, depth = entry
        raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", root) if depth >= Limits::MAX_BTREE_DEPTH
        raise CorruptDatabase.new("b-tree reaches the page twice", page_number) unless seen.add?(page_number)
        @pager.check_page_number(page_number)
        node = load_node(page_number)
        node.list_of_cells.each do |cell|
          free_overflow(cell, node.page_type) unless node.page_type.interior_table?
          stack << {get_u32(cell, 0), depth + 1} if node.page_type.interior?
        end
        stack << {node.right_child, depth + 1} if node.page_type.interior?
        @pager.free_page(page_number)
      end
    end

    # --- Table b-trees ----------------------------------------------------

    # Stores *record* under *rowid*, replacing the row with that rowid.
    def table_insert(root : UInt32, rowid : Int64, record : Bytes) : Nil
      table_insert(root, rowid, record, replace: true)
    end

    # Adds the row unless *rowid* is already present, in one descent of the
    # tree; returns false (changing nothing) when it is.
    def table_insert_new(root : UInt32, rowid : Int64, record : Bytes) : Bool
      table_insert(root, rowid, record, replace: false)
    end

    private def table_insert(root : UInt32, rowid : Int64, record : Bytes, *, replace : Bool) : Bool
      path, leaf, index, found = seek_rowid(root, rowid)
      return false if found && !replace
      cell = build_cell(PageType::LeafTable, record, rowid)
      editor = PageEditor.new(@pager.page_for_write(leaf), leaf, usable)
      if found
        free_overflow(editor.cell(index), PageType::LeafTable)
        editor.remove_cell(index)
      end
      if editor.insert_cell(index, cell)
        balance(path, load_node(leaf)) if found && underfull?(path, editor)
        return true
      end
      if !found && index == editor.cell_count && quick_balance_possible?(path)
        balance_quick(path, editor, cell)
        return true
      end
      node = load_node(leaf)
      node.list_of_cells.insert(index, cell)
      balance(path, node)
      true
    end

    # Deletes the row with *rowid*. Returns false when there is none.
    def table_delete(root : UInt32, rowid : Int64) : Bool
      path, leaf, index, found = seek_rowid(root, rowid)
      return false unless found
      editor = PageEditor.new(@pager.page_for_write(leaf), leaf, usable)
      free_overflow(editor.cell(index), PageType::LeafTable)
      editor.remove_cell(index)
      balance(path, load_node(leaf)) if underfull?(path, editor)
      true
    end

    # The record stored under *rowid*, or nil.
    def table_record(root : UInt32, rowid : Int64) : Bytes?
      _path, leaf, index, found = seek_rowid(root, rowid)
      return unless found
      page = BTreePage.read(@pager, leaf)
      PayloadReader.read(@pager, page, page.payload(index)).dup
    end

    # Whether the table holds a row with *rowid*.
    def table_contains?(root : UInt32, rowid : Int64) : Bool
      seek_rowid(root, rowid)[3]
    end

    # The largest rowid of the table, or nil when it is empty.
    def table_max_rowid(root : UInt32) : Int64?
      largest_rowid(root, 0)
    end

    private def largest_rowid(page_number : UInt32, depth : Int32) : Int64?
      raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", page_number) if depth >= Limits::MAX_BTREE_DEPTH
      page = BTreePage.read(@pager, page_number)
      page.corrupt("#{page.page_type} page in a table b-tree") unless page.page_type.table?
      if page.page_type.leaf_table?
        return page.cell_count > 0 ? page.rowid(page.cell_count - 1) : nil
      end
      if found = largest_rowid(page.right_child, depth + 1)
        return found
      end
      (page.cell_count - 1).downto(0) do |index|
        if found = largest_rowid(page.left_child(index), depth + 1)
          return found
        end
      end
      nil
    end

    private def seek_rowid(root : UInt32, rowid : Int64) : {Array(PathEntry), UInt32, Int32, Bool}
      path = [] of PathEntry
      page_number = root
      Limits::MAX_BTREE_DEPTH.times do
        page = BTreePage.read(@pager, page_number)
        page.corrupt("#{page.page_type} page in a table b-tree") unless page.page_type.table?
        low = 0
        high = page.cell_count
        while low < high
          middle = (low + high) // 2
          if page.rowid(middle) < rowid
            low = middle + 1
          else
            high = middle
          end
        end
        if page.page_type.leaf_table?
          return {path, page_number, low, low < page.cell_count && page.rowid(low) == rowid}
        end
        path << {page_number, low}
        page_number = low < page.cell_count ? page.left_child(low) : page.right_child
      end
      raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", root)
    end

    # --- Index b-trees ----------------------------------------------------

    # Adds the entry *key* (already in stored form) to the index b-tree.
    def index_insert(root : UInt32, key : Array(Value), comparator : KeyComparator) : Nil
      path, page_number, index, found, _leaf = seek_key(root, key, comparator)
      raise CorruptDatabase.new("index b-tree already holds the entry", page_number) if found
      cell = build_cell(PageType::LeafIndex, RecordEncoder.encode(key, @encoding, @schema_format))
      editor = PageEditor.new(@pager.page_for_write(page_number), page_number, usable)
      return if editor.insert_cell(index, cell)
      node = load_node(page_number)
      node.list_of_cells.insert(index, cell)
      balance(path, node)
    end

    # Removes the entry equal to *key*. Returns false when there is none.
    # An entry on an interior page is replaced by its predecessor, the
    # largest entry of its left subtree, as sqlite3BtreeDelete does.
    def index_delete(root : UInt32, key : Array(Value), comparator : KeyComparator) : Bool
      path, page_number, index, found, leaf = seek_key(root, key, comparator)
      return false unless found
      if leaf
        editor = PageEditor.new(@pager.page_for_write(page_number), page_number, usable)
        free_overflow(editor.cell(index), PageType::LeafIndex)
        editor.remove_cell(index)
        balance(path, load_node(page_number)) if underfull?(path, editor)
        return true
      end
      interior = load_node(page_number)
      doomed = interior.list_of_cells[index]
      free_overflow(doomed, PageType::InteriorIndex)
      predecessor_path = path + [{page_number, index}]
      child = get_u32(doomed, 0)
      Limits::MAX_BTREE_DEPTH.times do
        page = BTreePage.read(@pager, child)
        page.corrupt("#{page.page_type} page in an index b-tree") if page.page_type.table?
        break if page.page_type.leaf?
        predecessor_path << {child, page.cell_count}
        child = page.right_child
      end
      leaf_node = load_node(child)
      raise CorruptDatabase.new("index leaf has no entries", child) unless leaf_node.page_type.leaf_index?
      predecessor = leaf_node.list_of_cells.pop? || raise CorruptDatabase.new("index leaf has no entries", child)
      interior.list_of_cells[index] = with_child(get_u32(doomed, 0), predecessor)
      balance(predecessor_path, leaf_node, {page_number => interior})
      true
    end

    # The first entry whose leading *count* values are at least *prefix*,
    # or nil when every entry is smaller.
    def index_first_at_least(root : UInt32, prefix : Array(Value), count : Int32, comparator : KeyComparator) : Array(Value)?
      first_at_least(root, prefix, count, comparator, 0)
    end

    private def first_at_least(page_number : UInt32, prefix : Array(Value), count : Int32, comparator : KeyComparator, depth : Int32) : Array(Value)?
      raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", page_number) if depth >= Limits::MAX_BTREE_DEPTH
      page = BTreePage.read(@pager, page_number)
      page.corrupt("#{page.page_type} page in an index b-tree") if page.page_type.table?
      low = 0
      high = page.cell_count
      found = nil
      while low < high
        middle = (low + high) // 2
        entry = entry_record(page, middle)
        if comparator.compare(entry, prefix, count) < 0
          low = middle + 1
        else
          high = middle
          found = entry
        end
      end
      unless page.page_type.leaf?
        child = low < page.cell_count ? page.left_child(low) : page.right_child
        if deeper = first_at_least(child, prefix, count, comparator, depth + 1)
          return deeper
        end
      end
      low < page.cell_count ? (found || entry_record(page, low)) : nil
    end

    private def seek_key(root : UInt32, key : Array(Value), comparator : KeyComparator) : {Array(PathEntry), UInt32, Int32, Bool, Bool}
      path = [] of PathEntry
      page_number = root
      Limits::MAX_BTREE_DEPTH.times do
        page = BTreePage.read(@pager, page_number)
        page.corrupt("#{page.page_type} page in an index b-tree") if page.page_type.table?
        low = 0
        high = page.cell_count
        equal = false
        while low < high
          middle = (low + high) // 2
          result = comparator.compare(entry_record(page, middle), key)
          if result < 0
            low = middle + 1
          else
            high = middle
            equal = result == 0
          end
        end
        equal = false unless low < page.cell_count
        return {path, page_number, low, equal, page.page_type.leaf?} if equal || page.page_type.leaf?
        path << {page_number, low}
        page_number = low < page.cell_count ? page.left_child(low) : page.right_child
      end
      raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", root)
    end

    private def entry_record(page : BTreePage, index : Int32) : Array(Value)
      Record.decode(PayloadReader.read(@pager, page, page.payload(index)), @encoding, page.number)
    end

    # --- Cells and overflow chains ----------------------------------------

    # A leaf cell holding *payload*: its size, the rowid for a table leaf,
    # the bytes kept on the page and, when it spills, the first page of the
    # overflow chain that holds the rest.
    def build_cell(page_type : PageType, payload : Bytes, rowid : Int64 = 0_i64) : Bytes
      table_leaf = page_type.leaf_table?
      local = PageEditor.local_payload_size(usable, payload.size.to_i64, table_leaf)
      header = Varint.size(payload.size.to_i64) + (table_leaf ? Varint.size(rowid) : 0)
      spills = local < payload.size
      cell = Bytes.new(header + local + (spills ? 4 : 0))
      position = Varint.encode(payload.size.to_i64, cell, 0)
      position += Varint.encode(rowid, cell, position) if table_leaf
      (cell + position).copy_from(payload.to_unsafe, local)
      put_u32(cell, position + local, write_overflow(payload, local)) if spills
      cell
    end

    # An interior table cell: the left child and the largest rowid in it.
    def interior_table_cell(child : UInt32, rowid : Int64) : Bytes
      cell = Bytes.new(4 + Varint.size(rowid))
      put_u32(cell, 0, child)
      Varint.encode(rowid, cell, 4)
      cell
    end

    private def with_child(child : UInt32, content : Bytes) : Bytes
      cell = Bytes.new(4 + content.size)
      put_u32(cell, 0, child)
      (cell + 4).copy_from(content.to_unsafe, content.size)
      cell
    end

    private def write_overflow(payload : Bytes, from : Int32) : UInt32
      first = 0_u32
      previous = nil
      position = from
      capacity = usable - 4
      while position < payload.size
        page_number = @pager.allocate_page
        buffer = @pager.page_for_write(page_number)
        if previous
          put_u32(previous, 0, page_number)
        else
          first = page_number
        end
        chunk = Math.min(capacity, payload.size - position)
        (buffer + 4).copy_from((payload + position).to_unsafe, chunk)
        previous = buffer
        position += chunk
      end
      first
    end

    # Releases the overflow chain of *cell*, if it has one.
    def free_overflow(cell : Bytes, page_type : PageType) : Nil
      start = page_type.interior_index? ? 4 : 0
      size, length = Varint.decode(cell, start)
      position = start + length
      if page_type.leaf_table?
        _rowid, rowid_length = Varint.decode(cell, position)
        position += rowid_length
      end
      local = PageEditor.local_payload_size(usable, size, page_type.leaf_table?)
      return unless local < size
      next_page = get_u32(cell, position + local)
      pages = ((size - local + usable - 5) // (usable - 4)).to_i32
      pages.times do
        raise CorruptDatabase.new("overflow chain ends early") if next_page == 0
        @pager.check_page_number(next_page)
        following = get_u32(@pager.read_page(next_page), 0)
        @pager.free_page(next_page)
        next_page = following
      end
    end

    # --- Balancing --------------------------------------------------------

    private def load_node(page_number : UInt32) : TreeNode
      editor = PageEditor.new(@pager.read_page(page_number), page_number, usable)
      type = editor.page_type
      TreeNode.new(page_number, type, editor.list_of_cells, type.interior? ? editor.right_child : 0_u32)
    end

    private def write_node(node : TreeNode) : Nil
      editor = PageEditor.new(@pager.page_for_write(node.page_number), node.page_number, usable)
      editor.rebuild(node.page_type, node.list_of_cells, node.right_child)
    end

    private def used_space(node : TreeNode) : Int32
      node.list_of_cells.sum { |cell| PageEditor.cost(cell.size) }
    end

    private def fits?(node : TreeNode) : Bool
      used_space(node) <= PageEditor.capacity(node.page_number, node.page_type, usable)
    end

    # btree.c balances a non-root page whose free space passes two thirds
    # of the page.
    private def underfull?(node : TreeNode) : Bool
      free = PageEditor.capacity(node.page_number, node.page_type, usable) - used_space(node)
      free * 3 > usable * 2
    end

    private def underfull?(path : Array(PathEntry), editor : PageEditor) : Bool
      !path.empty? && editor.free_space * 3 > usable * 2
    end

    private def quick_balance_possible?(path : Array(PathEntry)) : Bool
      parent_entry = path.last?
      return false unless parent_entry
      parent_number, child_index = parent_entry
      return false if parent_number == 1
      child_index == BTreePage.read(@pager, parent_number).cell_count
    end

    # balance_quick: a row appended past the end of the rightmost leaf goes
    # to a new right sibling of its own, leaving the full leaf full, as
    # SQLite does for ascending inserts.
    private def balance_quick(path : Array(PathEntry), leaf : PageEditor, new_cell : Bytes) : Nil
      last_rowid = cell_rowid(leaf.cell(leaf.cell_count - 1))
      new_page = @pager.allocate_page
      write_node(TreeNode.new(new_page, PageType::LeafTable, [new_cell], 0_u32))
      parent_number, _child_index = path.pop
      divider = interior_table_cell(leaf.number, last_rowid)
      parent = PageEditor.new(@pager.page_for_write(parent_number), parent_number, usable)
      # The divider goes after the parent's last cell, and the new leaf
      # becomes its right child; only when the parent is full does it need
      # balancing (SQLite's balance_quick, then balance of the parent).
      if parent.insert_cell(parent.cell_count, divider)
        parent.right_child = new_page
        return
      end
      node = load_node(parent_number)
      node.list_of_cells << divider
      node.right_child = new_page
      balance(path, node)
    end

    private def cell_rowid(cell : Bytes) : Int64
      _size, length = Varint.decode(cell, 0)
      rowid, _rowid_length = Varint.decode(cell, length)
      rowid
    end

    # Writes *node* back, balancing it and then its ancestors as needed.
    # *list_of_pending* holds changed ancestors (by page) that are written or
    # balanced after the pages below them.
    private def balance(path : Array(PathEntry), node : TreeNode, list_of_pending : Hash(UInt32, TreeNode) = {} of UInt32 => TreeNode) : Nil
      loop do
        if path.empty?
          if !fits?(node)
            balance_deeper(node)
            next
          end
          if node.page_type.interior? && node.list_of_cells.empty?
            balance_shallower(node)
          else
            write_node(node)
          end
          return
        end
        if fits?(node) && !underfull?(node)
          write_node(node)
          return if list_of_pending.empty?
          pending = nil
          while entry = path.pop?
            if pending = list_of_pending.delete(entry[0])
              break
            end
          end
          return unless pending
          node = pending
          next
        end
        parent_number, child_index = path.pop
        parent = list_of_pending.delete(parent_number) || load_node(parent_number)
        balance_nonroot(parent, child_index, node)
        node = parent
      end
    end

    # balance_deeper: the root's contents move to a new child, and the root
    # becomes an interior page above it.
    private def balance_deeper(root : TreeNode) : Nil
      child = TreeNode.new(@pager.allocate_page, root.page_type, root.list_of_cells, root.right_child)
      root.page_type = root.page_type.table? ? PageType::InteriorTable : PageType::InteriorIndex
      root.list_of_cells = [] of Bytes
      root.right_child = child.page_number
      balance_nonroot(root, 0, child)
    end

    # An interior root with no cells takes its only child's contents when
    # they fit (page 1 has 100 bytes less room).
    private def balance_shallower(root : TreeNode) : Nil
      child = load_node(root.right_child)
      lifted = TreeNode.new(root.page_number, child.page_type, child.list_of_cells, child.right_child)
      if fits?(lifted)
        write_node(lifted)
        @pager.free_page(child.page_number)
      else
        write_node(root)
      end
    end

    # Spreads the cells of the child at *child_index* of *parent* (given as
    # *node*) and of up to two neighbors over as many pages as they need,
    # and updates the dividers in *parent* (which is changed in memory and
    # not written).
    private def balance_nonroot(parent : TreeNode, child_index : Int32, node : TreeNode) : Nil
      list_of_children = parent.list_of_cells.map { |cell| get_u32(cell, 0) }
      list_of_children << parent.right_child
      list_of_dividers = parent.list_of_cells.map { |cell| cell[4..] }
      child_count = list_of_children.size
      first = if child_count <= 3 || child_index == 0
                0
              elsif child_index == child_count - 1
                child_count - 3
              else
                child_index - 1
              end
      last = Math.min(first + 2, child_count - 1)
      siblings = (first..last).map do |position|
        position == child_index ? node : load_node(list_of_children[position])
      end
      type = node.page_type
      siblings.each do |sibling|
        if sibling.page_type != type
          raise CorruptDatabase.new("#{sibling.page_type} page beside a #{type} page", sibling.page_number)
        end
      end
      cells = [] of Bytes
      siblings.each_with_index do |sibling, position|
        cells.concat(sibling.list_of_cells)
        next if position == siblings.size - 1
        divider = list_of_dividers[first + position]
        case type
        when .interior_table?, .interior_index?
          cells << with_child(sibling.right_child, divider)
        when .leaf_index?
          cells << divider
        end
      end
      final_right = siblings.last.right_child
      consume = !type.leaf_table?
      groups, divider_positions = distribute(cells, consume, PageEditor.capacity(2_u32, type, usable))
      old_pages = siblings.map(&.page_number)
      new_pages = Array(UInt32).new(groups.size) { |position| position < old_pages.size ? old_pages[position] : @pager.allocate_page }
      old_pages.each_with_index { |page_number, position| @pager.free_page(page_number) if position >= groups.size }
      new_dividers = [] of Bytes
      groups.each_with_index do |group, position|
        list_of_group_cells = group.map { |cell_position| cells[cell_position] }
        right = type.interior? ? final_right : 0_u32
        if position < groups.size - 1
          if type.leaf_table?
            last_cell = list_of_group_cells.last? || raise Error.new("empty page while splitting a table leaf")
            new_dividers << interior_table_cell(0_u32, cell_rowid(last_cell))[4..]
          else
            divider = cells[divider_positions[position]]
            if type.interior?
              right = get_u32(divider, 0)
              new_dividers << divider[4..]
            else
              new_dividers << divider
            end
          end
        end
        write_node(TreeNode.new(new_pages[position], type, list_of_group_cells, right))
      end
      list_of_children[first..last] = new_pages
      list_of_dividers[first...last] = new_dividers
      parent.list_of_cells = list_of_dividers.map_with_index { |divider, position| with_child(list_of_children[position], divider) }
      parent.right_child = list_of_children.last
    end

    # Splits *cells* into the fewest pages of *capacity*, then evens them
    # out right to left. With *consume*, the cell between two pages moves up
    # to the parent as their divider (index pages and interior pages).
    # Returns the cell positions of each page and of each divider.
    private def distribute(cells : Array(Bytes), consume : Bool, capacity : Int32) : {Array(Array(Int32)), Array(Int32)}
      groups = [[] of Int32]
      used = [0]
      dividers = [] of Int32
      cells.each_with_index do |cell, position|
        cost = PageEditor.cost(cell.size)
        if used.last + cost <= capacity
          groups.last << position
          used[-1] += cost
        elsif consume
          dividers << position
          groups << [] of Int32
          used << 0
        else
          groups << [position]
          used << cost
        end
      end
      if consume && groups.size > 1 && groups.last.empty?
        moved_down = dividers.pop
        groups.pop
        used.pop
        moved_up = groups.last.pop
        used[-1] -= PageEditor.cost(cells[moved_up].size)
        dividers << moved_up
        groups << [moved_down]
        used << PageEditor.cost(cells[moved_down].size)
      end
      (groups.size - 1).downto(1) do |right|
        loop do
          left = groups[right - 1]
          break if left.size <= 1
          leaving = left.last
          arriving = consume ? dividers[right - 1] : leaving
          new_right = used[right] + PageEditor.cost(cells[arriving].size)
          new_left = used[right - 1] - PageEditor.cost(cells[leaving].size)
          break if new_right > capacity || new_right > new_left
          groups[right].unshift(arriving)
          left.pop
          used[right] = new_right
          used[right - 1] = new_left
          dividers[right - 1] = leaving if consume
        end
      end
      {groups, dividers}
    end

    private def get_u32(bytes : Bytes, offset : Int32) : UInt32
      (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) | (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3]
    end

    private def put_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
      bytes[offset] = (value >> 24).to_u8!
      bytes[offset + 1] = (value >> 16).to_u8!
      bytes[offset + 2] = (value >> 8).to_u8!
      bytes[offset + 3] = value.to_u8!
    end
  end
end
