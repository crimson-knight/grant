module Grant::SQLiteEngine::Query
  # A position in a b-tree that moves one entry at a time, for the query
  # executor: a stack of pages from the root to the current entry. Every
  # page is read through the pager and checked by `BTreePage`; a child that
  # is already on the stack (a cycle) or a tree deeper than
  # `Limits::MAX_BTREE_DEPTH` is `CorruptDatabase`.
  abstract class BTreeCursor
    @stack = CursorPath.new
    @valid = false

    def initialize(@database : Database, @root_page : UInt32)
    end

    # True while the cursor is on an entry.
    def valid? : Bool
      @valid
    end

    protected def pager : Pager
      @database.pager
    end

    protected def open_page(number : UInt32, table : Bool) : BTreePage
      if @stack.size >= Limits::MAX_BTREE_DEPTH
        raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", number)
      end
      if @stack.reaches?(number)
        raise CorruptDatabase.new("b-tree reaches the page twice", number)
      end
      page = BTreePage.read(pager, number)
      page.corrupt("#{page.page_type} page in a #{table ? "table" : "index"} b-tree") unless page.page_type.table? == table
      page
    end

    protected def child_of(page : BTreePage, index : Int32) : UInt32
      index < page.cell_count ? page.left_child(index) : page.right_child
    end
  end

  # sqlite3BtreeCount: the entries of a b-tree, counted from its pages'
  # cell counts without decoding a record. A table b-tree keeps its rows
  # in leaf cells; an index b-tree keeps entries in interior cells too.
  module BTreeCount
    def self.entries(database : Database, root_page : UInt32, session : Session) : Int64
      pager = database.pager
      pager.check_page_number(root_page)
      total = 0_i64
      pending = [root_page]
      visited = Set(UInt32).new
      while number = pending.pop?
        raise CorruptDatabase.new("b-tree reaches the page twice", number) unless visited.add?(number)
        session.tick
        page = BTreePage.read(pager, number)
        if page.page_type.leaf?
          total += page.cell_count
        else
          total += page.cell_count unless page.page_type.table?
          page.cell_count.times { |index| pending << page.left_child(index) }
          pending << page.right_child
        end
      end
      total
    end
  end

  # The pages from a b-tree's root to a cursor's entry, each with the cell
  # index the cursor took there. Levels are objects reused from one descent
  # to the next, so a step moves an index in place.
  class CursorPath
    # One page of the path and the cell index taken on it.
    class Level
      property page : BTreePage
      property index : Int32

      def initialize(@page : BTreePage, @index : Int32)
      end
    end

    @list_of_levels = [] of Level
    getter size = 0

    def push(page : BTreePage, index : Int32) : Nil
      if @size < @list_of_levels.size
        level = @list_of_levels.unsafe_fetch(@size)
        level.page = page
        level.index = index
      else
        @list_of_levels << Level.new(page, index)
      end
      @size += 1
    end

    def pop : Nil
      @size -= 1 if @size > 0
    end

    def clear : Nil
      @size = 0
    end

    def empty? : Bool
      @size == 0
    end

    # The deepest level; the path must not be empty.
    def top : Level
      @list_of_levels.unsafe_fetch(@size - 1)
    end

    def top? : Level?
      @size > 0 ? top : nil
    end

    # True when a level of the path is page *number*.
    def reaches?(number : UInt32) : Bool
      @size.times { |depth| return true if @list_of_levels.unsafe_fetch(depth).page.number == number }
      false
    end
  end

  # A cursor over a table b-tree, in rowid order.
  class TableCursor < BTreeCursor
    @row_header = RecordHeader.new

    # Moves to the first row. Returns false for an empty table.
    def first : Bool
      seek(Int64::MIN)
    end

    # Moves to the first row whose rowid is at least *rowid*.
    def seek(rowid : Int64) : Bool
      @stack.clear
      number = @root_page
      # A zero-length file is an empty database: sqlite_schema has no rows.
      if number == 1_u32 && pager.page_count == 0_u32
        @valid = false
        return false
      end
      pager.check_page_number(number)
      loop do
        page = open_page(number, table: true)
        index = lower_bound(page, rowid)
        @stack.push(page, index)
        break if page.page_type.leaf?
        number = child_of(page, index)
      end
      settle
    end

    # Moves to the next row.
    def advance : Bool
      return false unless @valid
      top = @stack.top
      index = top.index + 1
      top.index = index
      # The next cell of the same leaf needs no climb.
      return true if index < top.page.cell_count
      settle
    end

    def rowid : Int64
      top = @stack.top
      top.page.rowid(top.index)
    end

    def record : Array(Value)
      top = @stack.top
      page = top.page
      _rowid, location = page.table_leaf_cell(top.index)
      Record.decode(PayloadReader.read(pager, page, location), @database.text_encoding, page.number)
    end

    # Decodes the current row of *table* into *into* in declared column
    # order, with only the columns *use* marks; returns its rowid.
    def row(table : TableInfo, use : ColumnUse, into : Array(Value)) : Int64
      header = @row_header
      rowid = header(header)
      table.decode_row(rowid, header, @database.text_encoding, use, into)
      rowid
    end

    # Reads the current row's record header into *header*; returns its
    # rowid.
    def header(into header : RecordHeader) : Int64
      top = @stack.top
      page = top.page
      index = top.index
      if cell = page.local_table_leaf_cell(index)
        rowid, payload = cell
      else
        rowid, location = page.table_leaf_cell(index)
        payload = PayloadReader.read(pager, page, location)
      end
      header.parse(payload, page.number)
      rowid
    end

    # From a leaf position that may be past the leaf's end, moves to the
    # next row there is.
    private def settle : Bool
      loop do
        top = @stack.top
        if top.index < top.page.cell_count
          @valid = true
          return true
        end
        @stack.pop
        loop do
          if @stack.empty?
            @valid = false
            return false
          end
          parent = @stack.top
          child = parent.index
          if child < parent.page.cell_count
            parent.index = child + 1
            descend_leftmost(child_of(parent.page, child + 1))
            break
          end
          @stack.pop
        end
      end
    end

    private def descend_leftmost(number : UInt32) : Nil
      loop do
        page = open_page(number, table: true)
        @stack.push(page, 0)
        break if page.page_type.leaf?
        number = child_of(page, 0)
      end
    end

    # The first cell whose key is at least *rowid* (an interior cell's key
    # is the largest rowid of its left subtree).
    private def lower_bound(page : BTreePage, rowid : Int64) : Int32
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
      low
    end
  end

  # How an index orders its records: the collation and direction of each
  # key column.
  record IndexOrder, collations : Array(Collation), descending : Array(Bool) do
    # Compares a record with a probe on the probe's columns.
    def compare(record : Array(Value), probe : Array(Value)) : Int32
      probe.each_with_index do |probe_value, position|
        stored = record[position]?
        comparison = ValueSemantics.compare(stored, probe_value, @collations[position]? || Collation::Binary)
        if comparison != 0
          return descending[position]? ? -comparison : comparison
        end
      end
      0
    end
  end

  # A cursor over an index b-tree, in key order. Interior pages hold
  # entries too, between their subtrees.
  class IndexCursor < BTreeCursor
    def initialize(database : Database, root_page : UInt32, @order : IndexOrder)
      super(database, root_page)
    end

    def first : Bool
      @built_generation = pager.generation
      @stack.clear
      pager.check_page_number(@root_page)
      descend_leftmost(@root_page)
      settle_leaf
    end

    # Moves to the first entry whose key columns compare at least (or, with
    # *strict*, greater than) *probe*.
    def seek(probe : Array(Value), strict : Bool = false) : Bool
      # sqlite3BtreeIndexMoveto: when the cursor sits on a leaf whose keys
      # span the target, the search stays in that leaf.
      if @valid && @built_generation == pager.generation && (top = @stack.top?) && top.page.page_type.leaf?
        leaf = top.page
        index = top.index
        if index < leaf.cell_count
          if below?(leaf, index, probe, strict)
            # A join probes in ascending order, so the target is usually a
            # few entries past the current one.
            if forward = forward_bound(leaf, index, probe, strict)
              top.index = forward
              return settle_leaf
            end
          elsif index > 0 && below?(leaf, index - 1, probe, strict)
            # The cursor already sits on the target: the previous probe
            # stopped at the first entry past its key, where this one starts.
            return settle_leaf
          end
        end
        if leaf_spans?(leaf, probe, strict)
          top.index = bound(leaf, probe, strict)
          return settle_leaf
        end
      end
      @built_generation = pager.generation
      @stack.clear
      number = @root_page
      pager.check_page_number(number)
      loop do
        page = open_page(number, table: false)
        index = bound(page, probe, strict)
        @stack.push(page, index)
        break if page.page_type.leaf?
        number = child_of(page, index)
      end
      settle_leaf
    end

    def advance : Bool
      return false unless @valid
      top = @stack.top
      index = top.index + 1
      top.index = index
      return settle_leaf if top.page.page_type.leaf?
      # On an interior cell: continue in the subtree to its right.
      descend_leftmost(child_of(top.page, index))
      settle_leaf
    end

    def record : Array(Value)
      top = @stack.top
      Record.decode(entry_payload(top.page, top.index), @database.text_encoding, top.page.number)
    end

    # The current entry decoded into *into*.
    def record(into : Array(Value)) : Array(Value)
      top = @stack.top
      page = top.page
      RecordColumns.decode_into(entry_payload(page, top.index), @database.text_encoding, page.number, into)
    end

    # The payload of entry *index* of *page*: a slice of the page when it
    # does not spill, read through the overflow chain otherwise.
    private def entry_payload(page : BTreePage, index : Int32) : Bytes
      page.local_index_payload(index) || PayloadReader.read(pager, page, page.payload(index))
    end

    private def descend_leftmost(number : UInt32) : Nil
      loop do
        page = open_page(number, table: false)
        @stack.push(page, 0)
        break if page.page_type.leaf?
        number = child_of(page, 0)
      end
    end

    # From a leaf position, moves to the entry there: the leaf cell, or
    # the next interior cell up the stack once the leaf is used up.
    private def settle_leaf : Bool
      top = @stack.top
      if top.index < top.page.cell_count
        @valid = true
        return true
      end
      @stack.pop
      loop do
        if @stack.empty?
          @valid = false
          return false
        end
        parent = @stack.top
        if parent.index < parent.page.cell_count
          @valid = true
          return true
        end
        @stack.pop
      end
    end

    @built_generation = -1

    # True when the cursor is on an entry of the tree as it is now (no
    # write since it moved there).
    def positioned? : Bool
      @valid && @built_generation == pager.generation
    end

    # Forgets the position, so the next seek starts from the root (a new
    # execution may follow writes this connection made).
    def forget_position : Nil
      @valid = false
      @built_generation = -1
    end

    # True when the first entry at least (with *strict*, greater than)
    # *probe* lies in *leaf*: its first key is below that and its last
    # key is not.
    private def leaf_spans?(leaf : BTreePage, probe : Array(Value), strict : Bool) : Bool
      count = leaf.cell_count
      return false if count == 0
      first = compare_entry(leaf, 0, probe)
      return false unless strict ? first <= 0 : first < 0
      last = compare_entry(leaf, count - 1, probe)
      strict ? last > 0 : last >= 0
    end

    # The first leaf entry at least (with *strict*, greater than) *probe*
    # when a later entry of *leaf* than *index* (an entry below it) is not
    # below it; nil otherwise. Steps ahead 1, 2, 4... entries, then
    # searches the last step.
    private def forward_bound(leaf : BTreePage, index : Int32, probe : Array(Value), strict : Bool) : Int32?
      count = leaf.cell_count
      low = index + 1
      step = 1
      loop do
        candidate = index + step
        return if candidate >= count && below?(leaf, count - 1, probe, strict)
        if candidate >= count || !below?(leaf, candidate, probe, strict)
          return bound(leaf, probe, strict, low, Math.min(candidate, count - 1))
        end
        low = candidate + 1
        step *= 2
      end
    end

    # True when the entry at *index* sorts before the first entry *seek*
    # wants.
    private def below?(page : BTreePage, index : Int32, probe : Array(Value), strict : Bool) : Bool
      comparison = compare_entry(page, index, probe)
      comparison < 0 || (strict && comparison == 0)
    end

    # Compares entry *index* of *page* with *probe* in index order. A probe
    # of one integer against a stored integer compares the two directly
    # (vdbeRecordCompareInt); anything else goes through `compare_prefix`.
    private def compare_entry(page : BTreePage, index : Int32, probe : Array(Value)) : Int32
      payload = entry_payload(page, index)
      if probe.size == 1 && (key = probe.unsafe_fetch(0)).is_a?(Int64)
        if comparison = RecordColumns.compare_integer_key(payload, key)
          return @order.descending[0]? ? -comparison : comparison
        end
      end
      RecordColumns.compare_prefix(payload, @database.text_encoding, page.number, probe, @order)
    end

    private def bound(page : BTreePage, probe : Array(Value), strict : Bool, low : Int32 = 0, high : Int32 = page.cell_count) : Int32
      while low < high
        middle = (low + high) // 2
        comparison = compare_entry(page, middle, probe)
        if comparison < 0 || (strict && comparison == 0)
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end
  end
end
