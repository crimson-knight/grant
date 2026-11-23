module Grant::SQLiteEngine
  # A row of a table: its rowid (nil for a WITHOUT ROWID table) and its
  # values in declared column order.
  record Row, rowid : Int64?, values : Array(Value)

  # A SQLite database opened read-only.
  #
  # Rows come back in rowid order (primary key order for WITHOUT ROWID
  # tables) and index entries in key order, each value decoded as SQLite
  # would return it: the rowid for an INTEGER PRIMARY KEY column, REAL
  # affinity applied to whole numbers SQLite stored as integers, and the
  # column DEFAULT for rows written before an ALTER TABLE ADD COLUMN.
  class Database
    getter pager : Pager

    @schema : Schema? = nil

    # Opens the file at *path* read-only, with its `-wal` file when one
    # exists. Neither file, nor any `-shm` file, is written.
    def self.open(path : String | Path) : Database
      main = FileByteSource.new(path)
      wal_path = "#{path}-wal"
      wal = File.exists?(wal_path) ? FileByteSource.new(wal_path) : nil
      begin
        new(Pager.new(main, wal))
      rescue error : Error
        main.close
        wal.try &.close
        raise error
      end
    end

    # Opens a database held in memory, with an optional WAL image.
    def self.from_bytes(bytes : Bytes, wal_bytes : Bytes? = nil) : Database
      wal = wal_bytes ? MemoryByteSource.new(wal_bytes) : nil
      new(Pager.new(MemoryByteSource.new(bytes), wal))
    end

    def initialize(@pager : Pager)
    end

    # The database header; nil for an empty (zero-page) database.
    def header : DatabaseHeader?
      @pager.header
    end

    def page_count : UInt32
      @pager.page_count
    end

    def text_encoding : TextEncoding
      header.try(&.text_encoding) || TextEncoding::UTF8
    end

    # The schema, read from `sqlite_schema` on first use.
    def schema : Schema
      @schema ||= read_schema
    end

    # Yields every row of *table_name*.
    def each_row(table_name : String, & : Row ->) : Nil
      each_row(schema.entry(table_name)) { |row| yield row }
    end

    # Yields every row of the table *entry* names.
    def each_row(entry : SchemaEntry, & : Row ->) : Nil
      raise UnknownSchemaObject.new(entry.object_name) unless entry.table? && entry.has_a_btree?
      definition = schema.table_definition(entry)
      mapping = RowMapping.new(entry.object_name, definition)
      if definition.without_rowid?
        each_index_btree_record(entry.root_page) { |record| yield Row.new(nil, mapping.map(nil, record)) }
      else
        each_table_btree_record(entry.root_page) { |rowid, record| yield Row.new(rowid, mapping.map(rowid, record)) }
      end
    end

    # Every row of *table_name*.
    def rows(table_name : String) : Array(Row)
      list_of_rows = [] of Row
      each_row(table_name) { |row| list_of_rows << row }
      list_of_rows
    end

    # Yields every entry of the index *index_name* in key order: the key
    # values followed by the rowid, or by the primary key columns for an
    # index on a WITHOUT ROWID table.
    def each_index_entry(index_name : String, & : Array(Value) ->) : Nil
      each_index_entry(schema.entry(index_name)) { |record| yield record }
    end

    # Yields every entry of the index *entry* names.
    def each_index_entry(entry : SchemaEntry, & : Array(Value) ->) : Nil
      raise UnknownSchemaObject.new(entry.object_name) unless entry.index? && entry.has_a_btree?
      affinities = schema.index_record_affinities(entry)
      each_index_btree_record(entry.root_page) do |record|
        record.each_with_index do |value, position|
          affinity = affinities[position]?
          record[position] = value.to_f64 if value.is_a?(Int64) && affinity && affinity.real?
        end
        yield record
      end
    end

    # Looks up the row of *table_name* with *rowid* by descending the table
    # b-tree. Returns nil when there is none.
    def find_row(table_name : String, rowid : Int64) : Row?
      entry = schema.entry(table_name)
      raise UnknownSchemaObject.new(table_name) unless entry.table? && entry.has_a_btree?
      definition = schema.table_definition(entry)
      raise UnsupportedSQL.new("rowid lookup in WITHOUT ROWID table #{entry.object_name}") if definition.without_rowid?
      record = find_table_record(entry.root_page, rowid)
      return unless record
      Row.new(rowid, RowMapping.new(entry.object_name, definition).map(rowid, record))
    end

    # The freelist, walked from the header.
    def freelist : Freelist
      current_header = header
      return Freelist.new([] of UInt32, [] of UInt32) unless current_header
      Freelist.read(@pager, current_header)
    end

    # The pointer-map entries of an auto-vacuum database.
    def pointer_map_entries : Array(PointerMap::Entry)
      current_header = header
      return [] of PointerMap::Entry unless current_header
      PointerMap.read(@pager, current_header)
    end

    def close : Nil
      @pager.close
    end

    # Yields the rowid and decoded record of every cell of the table b-tree
    # rooted at *root_page*, in rowid order.
    def each_table_btree_record(root_page : UInt32, & : Int64, Array(Value) ->) : Nil
      walk(root_page, table: true) do |page, cell|
        location = page.payload(cell)
        payload = PayloadReader.read(@pager, page, location)
        yield page.rowid(cell), Record.decode(payload, text_encoding, page.number)
      end
    end

    # Yields the decoded record of every entry of the index b-tree rooted at
    # *root_page*, in key order (interior cells between their subtrees).
    def each_index_btree_record(root_page : UInt32, & : Array(Value) ->) : Nil
      walk(root_page, table: false) do |page, cell|
        location = page.payload(cell)
        payload = PayloadReader.read(@pager, page, location)
        yield Record.decode(payload, text_encoding, page.number)
      end
    end

    # Depth-first walk yielding each cell that carries a payload, in order.
    # Every page is checked to be of the tree's kind, the depth is bounded,
    # and no page may be reached twice (which would mean a cycle or a page
    # shared between subtrees).
    private def walk(root_page : UInt32, table : Bool, & : BTreePage, Int32 ->) : Nil
      @pager.check_page_number(root_page)
      visited = Set(UInt32).new
      stack = [] of {BTreePage, Int32}
      stack << {open_tree_page(root_page, table, visited, 0), 0}
      while frame = stack.last?
        page, step = frame
        if page.page_type.leaf?
          page.cell_count.times { |cell| yield page, cell }
          stack.pop
          next
        end
        cell_count = page.cell_count
        if table
          if step < cell_count
            stack[-1] = {page, step + 1}
            stack << {open_tree_page(page.left_child(step), table, visited, stack.size), 0}
          elsif step == cell_count
            stack[-1] = {page, step + 1}
            stack << {open_tree_page(page.right_child, table, visited, stack.size), 0}
          else
            stack.pop
          end
        else
          # Index interior pages hold keys too: child 0, key 0, child 1, ...
          # key n-1, then the right child.
          if step < 2 * cell_count
            stack[-1] = {page, step + 1}
            if step.even?
              stack << {open_tree_page(page.left_child(step // 2), table, visited, stack.size), 0}
            else
              yield page, step // 2
            end
          elsif step == 2 * cell_count
            stack[-1] = {page, step + 1}
            stack << {open_tree_page(page.right_child, table, visited, stack.size), 0}
          else
            stack.pop
          end
        end
      end
    end

    private def open_tree_page(page_number : UInt32, table : Bool, visited : Set(UInt32), depth : Int32) : BTreePage
      raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", page_number) if depth >= Limits::MAX_BTREE_DEPTH
      raise CorruptDatabase.new("b-tree reaches the page twice", page_number) unless visited.add?(page_number)
      page = BTreePage.read(@pager, page_number)
      if page.page_type.table? != table
        page.corrupt("#{page.page_type} page in a #{table ? "table" : "index"} b-tree")
      end
      page
    end

    private def find_table_record(root_page : UInt32, rowid : Int64) : Array(Value)?
      @pager.check_page_number(root_page)
      page_number = root_page
      Limits::MAX_BTREE_DEPTH.times do
        page = BTreePage.read(@pager, page_number)
        page.corrupt("#{page.page_type} page in a table b-tree") unless page.page_type.table?
        if page.page_type.leaf_table?
          cell = lower_bound(page, rowid)
          return if cell >= page.cell_count || page.rowid(cell) != rowid
          payload = PayloadReader.read(@pager, page, page.payload(cell))
          return Record.decode(payload, text_encoding, page.number)
        end
        # An interior cell's key is the largest rowid in its left subtree.
        cell = lower_bound(page, rowid)
        page_number = cell < page.cell_count ? page.left_child(cell) : page.right_child
      end
      raise CorruptDatabase.new("b-tree is deeper than #{Limits::MAX_BTREE_DEPTH} pages", root_page)
    end

    # First cell whose key is at least *rowid*.
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

    # sqlite_schema is the table b-tree rooted at page 1, with the columns
    # type, name, tbl_name, rootpage and sql.
    private def read_schema : Schema
      entries = [] of SchemaEntry
      return Schema.new(entries) if @pager.page_count == 0
      each_table_btree_record(1_u32) do |_rowid, record|
        entries << schema_entry(record)
      end
      Schema.new(entries)
    end

    private def schema_entry(record : Array(Value)) : SchemaEntry
      object_type = record[0]?
      object_name = record[1]?
      table_name = record[2]?
      root_page = record[3]?
      sql = record[4]?
      unless object_type.is_a?(String) && object_name.is_a?(String) && table_name.is_a?(String)
        raise CorruptDatabase.new("sqlite_schema row has a non-text type, name or tbl_name", 1_u32)
      end
      root = root_page.is_a?(Int64) ? root_page : 0_i64
      if root < 0 || root > @pager.page_count
        raise CorruptDatabase.new("sqlite_schema root page #{root} of #{object_name} is outside 0..#{@pager.page_count}", 1_u32)
      end
      SchemaEntry.new(object_type, object_name, table_name, root.to_u32, sql.is_a?(String) ? sql : nil)
    end

    # Maps a stored record to the table's declared columns.
    private struct RowMapping
      @stored_order : Array(Int32)
      @column_count : Int32

      def initialize(@table_name : String, @definition : TableDefinition)
        @stored_order = definition.stored_column_order
        @column_count = definition.list_of_columns.size
        if virtual = definition.list_of_columns.find(&.generated.virtual?)
          raise UnsupportedSQL.new("VIRTUAL generated column #{table_name}.#{virtual.column_name}")
        end
      end

      def map(rowid : Int64?, record : Array(Value)) : Array(Value)
        values = Array(Value).new(@column_count, nil)
        columns = @definition.list_of_columns
        @stored_order.each_with_index do |column_index, position|
          column = columns[column_index]
          values[column_index] = if position < record.size
                                   realify(column, record.unsafe_fetch(position))
                                 else
                                   default_for(column)
                                 end
        end
        alias_index = @definition.rowid_alias_index
        values[alias_index] = rowid if alias_index && rowid
        values
      end

      # datatype3.html §3.2: SQLite may store a REAL-affinity value that is a
      # whole number as an integer; it reads back as REAL.
      private def realify(column : ColumnDefinition, value : Value) : Value
        return value.to_f64 if value.is_a?(Int64) && column.affinity.real?
        value
      end

      private def default_for(column : ColumnDefinition) : Value
        if expression = column.default_expression
          raise UnsupportedSQL.new("DEFAULT #{expression} of #{@table_name}.#{column.column_name} for a row written before the column was added")
        end
        literal = column.default_real_literal
        return literal if literal && column.affinity.text?
        column.affinity.apply(column.default_value)
      end
    end
  end
end
