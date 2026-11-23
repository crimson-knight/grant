module Grant::SQLiteEngine::Query
  # A position in a b-tree that moves one entry at a time, for the query
  # executor: a stack of pages from the root to the current entry. Every
  # page is read through the pager and checked by `BTreePage`; a child that
  # is already on the stack (a cycle) or a tree deeper than
  # `Limits::MAX_BTREE_DEPTH` is `CorruptDatabase`.
  abstract class BTreeCursor
    @stack = [] of {BTreePage, Int32}
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
      if @stack.any? { |frame| frame[0].number == number }
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
        @stack << {page, index}
        break if page.page_type.leaf?
        number = child_of(page, index)
      end
      settle
    end

    # Moves to the next row.
    def advance : Bool
      return false unless @valid
      last = @stack.size - 1
      page, index = @stack.unsafe_fetch(last)
      @stack.unsafe_put(last, {page, index + 1})
      # The next cell of the same leaf needs no climb.
      return true if index + 1 < page.cell_count
      settle
    end

    def rowid : Int64
      page, index = @stack[-1]
      page.rowid(index)
    end

    def record : Array(Value)
      page, index = @stack[-1]
      _rowid, location = page.table_leaf_cell(index)
      Record.decode(PayloadReader.read(pager, page, location), @database.text_encoding, page.number)
    end

    # Decodes the current row of *table* into *into* in declared column
    # order, with only the columns *use* marks; returns its rowid.
    def row(table : TableInfo, use : ColumnUse, into : Array(Value)) : Int64
      page, index = @stack.unsafe_fetch(@stack.size - 1)
      rowid, location = page.table_leaf_cell(index)
      header = @row_header
      header.parse(PayloadReader.read(pager, page, location), page.number)
      table.decode_row(rowid, header, @database.text_encoding, use, into)
      rowid
    end

    # Reads the current row's record header into *header*; returns its
    # rowid.
    def header(into header : RecordHeader) : Int64
      page, index = @stack.unsafe_fetch(@stack.size - 1)
      rowid, location = page.table_leaf_cell(index)
      header.parse(PayloadReader.read(pager, page, location), page.number)
      rowid
    end

    # From a leaf position that may be past the leaf's end, moves to the
    # next row there is.
    private def settle : Bool
      loop do
        page, index = @stack[-1]
        if index < page.cell_count
          @valid = true
          return true
        end
        @stack.pop
        loop do
          if @stack.empty?
            @valid = false
            return false
          end
          parent, child = @stack[-1]
          if child < parent.cell_count
            @stack[-1] = {parent, child + 1}
            descend_leftmost(child_of(parent, child + 1))
            break
          end
          @stack.pop
        end
      end
    end

    private def descend_leftmost(number : UInt32) : Nil
      loop do
        page = open_page(number, table: true)
        @stack << {page, 0}
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
      if @valid && @built_generation == pager.generation && (top = @stack.last?) && top[0].page_type.leaf?
        leaf = top[0]
        # A join probes in ascending order, so the target is usually a
        # few entries past the current one.
        if forward = forward_bound(leaf, top[1], probe, strict)
          @stack[-1] = {leaf, forward}
          return settle_leaf
        end
        if leaf_spans?(leaf, probe, strict)
          @stack[-1] = {leaf, bound(leaf, probe, strict)}
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
        @stack << {page, index}
        break if page.page_type.leaf?
        number = child_of(page, index)
      end
      settle_leaf
    end

    def advance : Bool
      return false unless @valid
      page, index = @stack[-1]
      if page.page_type.leaf?
        @stack[-1] = {page, index + 1}
        return settle_leaf
      end
      # On interior cell `index`: continue in the subtree to its right.
      @stack[-1] = {page, index + 1}
      descend_leftmost(child_of(page, index + 1))
      settle_leaf
    end

    def record : Array(Value)
      page, index = @stack[-1]
      Record.decode(PayloadReader.read(pager, page, page.payload(index)), @database.text_encoding, page.number)
    end

    # The current entry decoded into *into*.
    def record(into : Array(Value)) : Array(Value)
      page, index = @stack.unsafe_fetch(@stack.size - 1)
      RecordColumns.decode_into(PayloadReader.read(pager, page, page.payload(index)), @database.text_encoding, page.number, into)
    end

    private def descend_leftmost(number : UInt32) : Nil
      loop do
        page = open_page(number, table: false)
        @stack << {page, 0}
        break if page.page_type.leaf?
        number = child_of(page, 0)
      end
    end

    # From a leaf position, moves to the entry there: the leaf cell, or
    # the next interior cell up the stack once the leaf is used up.
    private def settle_leaf : Bool
      page, index = @stack[-1]
      if index < page.cell_count
        @valid = true
        return true
      end
      @stack.pop
      loop do
        if @stack.empty?
          @valid = false
          return false
        end
        parent, child = @stack[-1]
        if child < parent.cell_count
          @valid = true
          return true
        end
        @stack.pop
      end
    end

    @built_generation = -1

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
      encoding = @database.text_encoding
      first = RecordColumns.compare_prefix(PayloadReader.read(pager, leaf, leaf.payload(0)), encoding, leaf.number, probe, @order)
      return false unless strict ? first <= 0 : first < 0
      last = RecordColumns.compare_prefix(PayloadReader.read(pager, leaf, leaf.payload(count - 1)), encoding, leaf.number, probe, @order)
      strict ? last > 0 : last >= 0
    end

    # The first leaf entry at least (with *strict*, greater than) *probe*
    # when the entry at *index* is below it and a later entry of *leaf* is
    # not; nil otherwise. Steps ahead 1, 2, 4... entries, then searches the
    # last step.
    private def forward_bound(leaf : BTreePage, index : Int32, probe : Array(Value), strict : Bool) : Int32?
      count = leaf.cell_count
      return if index >= count
      return unless below?(leaf, index, probe, strict)
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
      comparison = RecordColumns.compare_prefix(PayloadReader.read(pager, page, page.payload(index)), @database.text_encoding,
        page.number, probe, @order)
      comparison < 0 || (strict && comparison == 0)
    end

    private def bound(page : BTreePage, probe : Array(Value), strict : Bool, low : Int32 = 0, high : Int32 = page.cell_count) : Int32
      encoding = @database.text_encoding
      while low < high
        middle = (low + high) // 2
        comparison = RecordColumns.compare_prefix(PayloadReader.read(pager, page, page.payload(middle)), encoding, page.number,
          probe, @order)
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
