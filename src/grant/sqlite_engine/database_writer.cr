module Grant::SQLiteEngine
  # What the writer needs about one table: its definition, the order of the
  # values in its records, its indexes and, for a WITHOUT ROWID table, how
  # its primary key sorts.
  class TableLayout
    getter entry : SchemaEntry
    getter definition : TableDefinition
    getter list_of_stored_positions : Array(Int32)
    getter list_of_indexes : Array(IndexLayout)
    # WITHOUT ROWID tables: the primary key positions and the comparator of
    # the table's own b-tree.
    getter list_of_primary_key_positions : Array(Int32)
    getter comparator : KeyComparator?

    def initialize(@entry : SchemaEntry, @definition : TableDefinition, @list_of_indexes : Array(IndexLayout), encoding : TextEncoding)
      @list_of_stored_positions = definition.stored_column_order
      @list_of_primary_key_positions = [] of Int32
      @comparator = nil
      if definition.without_rowid?
        key = IndexLayout.primary_key_columns(definition)
        @list_of_primary_key_positions = key.map(&.[0])
        @comparator = KeyComparator.new(key.map(&.[1]), encoding)
      end
    end

    def table_name : String
      @entry.object_name
    end

    # How a stored record of this table maps to its declared columns, built
    # on first use and kept for the layout's life.
    getter row_mapping : Database::RowMapping { Database::RowMapping.new(table_name, definition) }
  end

  # The write API: schema changes, row inserts, updates and deletes, and
  # transactions. No SQL is parsed or run; CREATE statements are stored as
  # SQLite stores them, and the values of a row arrive in declared column
  # order.
  # The journal modes the writer implements: a rollback journal deleted at
  # each commit, and the write-ahead log.
  enum JournalMode
    Delete
    Wal
  end

  class Database
    SEQUENCE_TABLE     = "sqlite_sequence"
    SEQUENCE_TABLE_SQL = "CREATE TABLE sqlite_sequence(name,seq)"

    @table_layouts = {} of String => TableLayout
    # Page copies and cell lists every b-tree change on this database borrows.
    @btree_scratch = BTreeScratch.new
    # The buffer write_row encodes each table record into.
    @record_buffer = RecordEncoder::EncodeBuffer.new

    # Opens *path*. With `read_write: true` the database is created when the
    # file does not exist, a hot journal is rolled back, and the write API
    # works; *page_size* and *text_encoding* apply to a database the first
    # write creates; *cache_pages* bounds the pages kept in memory (nil sizes
    # the cache as SQLite's cache_size -2000 does); *file_system* is where
    # the files live (the crash simulator passes its own).
    #
    # *journal_mode* switches the database to WAL or back to a rollback
    # journal once it is open (nil keeps the mode its header records).
    # *synchronous* is PRAGMA synchronous, *wal_autocheckpoint* the WAL
    # size in frames that starts a passive checkpoint, and *busy_timeout*
    # how long a write or checkpoint waits for another connection.
    def self.open(path : String | Path, *, read_write : Bool, cache_pages : Int32? = nil,
                  page_size : Int32 = Limits::DEFAULT_PAGE_SIZE, text_encoding : TextEncoding = TextEncoding::UTF8,
                  file_system : FileSystem = FileSystem.native, journal_mode : JournalMode? = nil,
                  synchronous : Synchronous = Synchronous::Full,
                  wal_autocheckpoint : Int32 = Pager::DEFAULT_WAL_AUTOCHECKPOINT,
                  busy_timeout : Time::Span = Time::Span.zero) : Database
      return open(path) unless read_write
      pager = Pager.open_read_write(file_system, path.to_s, cache_pages, page_size, text_encoding, synchronous, wal_autocheckpoint)
      pager.busy_timeout = busy_timeout
      database = new(pager)
      begin
        database.journal_mode = journal_mode if journal_mode
      rescue error
        database.close
        raise error
      end
      database
    end

    # The journal mode the database is in.
    def journal_mode : JournalMode
      @pager.wal_mode? ? JournalMode::Wal : JournalMode::Delete
    end

    # Switches between a rollback journal and WAL (PRAGMA journal_mode).
    # Leaving WAL mode raises `Busy` while another connection has the
    # database open.
    def journal_mode=(mode : JournalMode) : JournalMode
      if mode.wal?
        @pager.enter_wal_mode
      else
        @pager.leave_wal_mode
      end
      mode
    end

    # Copies WAL frames into the database file (PRAGMA wal_checkpoint).
    def checkpoint(mode : CheckpointMode = CheckpointMode::Passive) : CheckpointResult
      @pager.checkpoint(mode)
    end

    def read_write? : Bool
      @pager.writable?
    end

    # Runs the block in one write transaction and commits it. An exception
    # rolls the transaction back and is raised again; `Rollback` rolls it
    # back quietly. Raises `Busy` when another connection holds the write
    # lock.
    def transaction(& : Database ->) : Nil
      raise Error.new("transactions do not nest") if @pager.in_write_transaction?
      began = BusyWait.attempt(@pager.busy_timeout) do
        @pager.begin_write
        true
      rescue Busy
        false
      end
      raise Busy.new unless began
      begin
        yield self
      rescue Rollback
        @pager.rollback
        return
      rescue error
        @pager.rollback
        raise error
      end
      raise Error.new("the transaction was rolled back by a failed write") unless @pager.in_write_transaction?
      begin
        @pager.commit
      rescue error
        @pager.rollback
        raise error
      end
    end

    # --- Schema -----------------------------------------------------------

    # Creates the table *sql* declares, with the automatic indexes of its
    # UNIQUE and PRIMARY KEY constraints and, for AUTOINCREMENT, the
    # sqlite_sequence table. Returns false when IF NOT EXISTS names an
    # existing table.
    def create_table(sql : String, attached_as : String? = nil) : Bool
      write_statement do
        statement = CreateStatement.table(sql, attached_as)
        definition = parse_table(sql)
        name = statement.object_name
        if existing = find_entry(name)
          next false if statement.if_not_exists? && existing.table?
          raise SchemaError.new(existing.table? ? "table #{name} already exists" : "there is already an index named #{name}")
        end
        check_new_name(name)
        check_table(definition)
        writer = btree_writer
        root = writer.create_tree(table: !definition.without_rowid?)
        insert_schema_row(writer, "table", name, name, root, statement.stored_sql)
        primary_key = definition.list_of_primary_key_columns.map(&.downcase)
        definition.list_of_unique_constraints.each_with_index do |columns, position|
          next if definition.without_rowid? && columns.map(&.downcase) == primary_key
          index_root = writer.create_tree(table: false)
          insert_schema_row(writer, "index", "sqlite_autoindex_#{name}_#{position + 1}", name, index_root, nil)
        end
        if definition.autoincrement? && find_entry(SEQUENCE_TABLE).nil?
          sequence_root = writer.create_tree(table: true)
          insert_schema_row(writer, "table", SEQUENCE_TABLE, SEQUENCE_TABLE, sequence_root, SEQUENCE_TABLE_SQL)
        end
        schema_changed
        true
      end
    end

    # Creates the index *sql* declares and fills it from the table's rows.
    # Returns false when IF NOT EXISTS names an existing index.
    def create_index(sql : String, attached_as : String? = nil) : Bool
      write_statement do
        statement = CreateStatement.index(sql, attached_as)
        definition = begin
          IndexDefinition.parse(sql)
        rescue error : SchemaTokenizer::Malformed
          raise SchemaError.new("malformed CREATE INDEX: #{error.message}")
        end
        name = statement.object_name
        if existing = find_entry(name)
          next false if statement.if_not_exists? && existing.index?
          raise SchemaError.new(existing.index? ? "index #{name} already exists" : "there is already a table named #{name}")
        end
        check_new_name(name)
        table_name = statement.table_name || raise SchemaError.new("CREATE INDEX names no table")
        table_entry = find_entry(table_name)
        raise SchemaError.new("no such table: #{table_name}") unless table_entry && table_entry.table? && table_entry.has_a_btree?
        raise SchemaError.new("table #{table_entry.object_name} may not be indexed") if table_entry.object_name.downcase.starts_with?("sqlite_")
        table = schema.table_definition(table_entry)
        definition.list_of_key_terms.each do |term|
          column_name = term.column_name
          # A double-quoted name that is no column is read as a string
          # literal (SQLite's double-quoted string literals, quirks.html §8),
          # which makes the term an expression.
          if column_name && table.column_index(column_name).nil? && !sql.includes?(%("#{column_name}"))
            raise SchemaError.new("no such column: #{column_name}")
          end
          if collation = term.collation
            Collation.named(collation)
          end
        end
        provisional = SchemaEntry.new("index", name, table_entry.object_name, 0_u32, statement.stored_sql)
        layout = IndexLayout.build(provisional, table, text_encoding)
        list_of_rows = [] of {Int64?, Array(Value)}
        each_row(table_entry) do |row|
          list_of_rows << {row.rowid, stored_row(table, row.values)}
        end
        if layout.needs_evaluation? && !list_of_rows.empty?
          raise UnsupportedSQL.new("index #{name} on existing rows outside a SQL session (its WHERE or expression terms)")
        end
        writer = btree_writer
        root = writer.create_tree(table: false)
        insert_schema_row(writer, "index", name, table_entry.object_name, root, statement.stored_sql)
        layout = IndexLayout.build(SchemaEntry.new("index", name, table_entry.object_name, root, statement.stored_sql), table, text_encoding)
        list_of_rows.each do |rowid, values|
          entry = layout.entry_for(values, rowid)
          check_unique(writer, layout, table_entry.object_name, entry)
          writer.index_insert(root, entry, layout.comparator)
        end
        schema_changed
        true
      end
    end

    # Drops the table or index *name*: a table with its indexes, triggers
    # and sqlite_sequence row. Every page they used goes to the freelist.
    def drop(name : String) : Nil
      write_statement do
        entry = schema.entry(name)
        writer = btree_writer
        if entry.table?
          raise SchemaError.new("table #{entry.object_name} may not be dropped") if entry.object_name.downcase.starts_with?("sqlite_") && !entry.object_name.downcase.starts_with?("sqlite_stat")
          dependents = schema.list_of_entries.select do |other|
            (other.index? || other.object_type == "trigger") && other.table_name.compare(entry.object_name, case_insensitive: true) == 0
          end
          dependents.each do |dependent|
            writer.free_tree(dependent.root_page) if dependent.has_a_btree?
            delete_schema_row(writer, dependent)
          end
          writer.free_tree(entry.root_page) if entry.has_a_btree?
          delete_schema_row(writer, entry)
          delete_sequence_row(writer, entry.object_name)
        elsif entry.index?
          raise SchemaError.new("index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped") if entry.sql.nil?
          writer.free_tree(entry.root_page)
          delete_schema_row(writer, entry)
        else
          raise UnsupportedSQL.new("dropping a #{entry.object_type}")
        end
        schema_changed
      end
    end

    # --- Rows -------------------------------------------------------------

    # Inserts a row of *values* (in declared column order) into a rowid
    # table and returns its rowid: *rowid* when given, else the INTEGER
    # PRIMARY KEY value when there is one, else one past the largest rowid.
    # Index entries are added; for a WITHOUT ROWID table *rowid* must be nil
    # and the result is nil. Raises `ConstraintViolation` and keeps nothing
    # when a UNIQUE, PRIMARY KEY, NOT NULL or STRICT rule fails.
    def insert(table_name : String, rowid : Int64?, values : Array(Value)) : Int64?
      write_statement(journal: false) do
        insert_row(table_layout(table_name), rowid, values, update_sequence: true)
      end
    end

    # Replaces the row with *rowid*. Setting the INTEGER PRIMARY KEY column
    # moves the row to that rowid. Returns false when there is no such row.
    def update(table_name : String, rowid : Int64, values : Array(Value)) : Bool
      write_statement do
        layout = table_layout(table_name)
        raise UnsupportedSQL.new("rowid lookup in WITHOUT ROWID table #{layout.table_name}") if layout.definition.without_rowid?
        old = read_row(layout, rowid)
        next false unless old
        delete_row(layout, old, rowid)
        alias_index = layout.definition.rowid_alias_index
        moved = alias_index && !values[alias_index]?.nil?
        insert_row(layout, moved ? nil : rowid, values, update_sequence: false)
        true
      end
    end

    # Replaces the row of a WITHOUT ROWID table whose primary key equals
    # *key* (the key columns' values, in key order).
    def update(table_name : String, key : Array(Value), values : Array(Value)) : Bool
      write_statement do
        layout = table_layout(table_name)
        old = read_row_by_key(layout, key)
        next false unless old
        delete_row(layout, old, nil)
        insert_row(layout, nil, values, update_sequence: false)
        true
      end
    end

    # Deletes the row with *rowid* and its index entries. Returns false when
    # there is no such row.
    def delete(table_name : String, rowid : Int64) : Bool
      write_statement(journal: false) do
        layout = table_layout(table_name)
        raise UnsupportedSQL.new("rowid lookup in WITHOUT ROWID table #{layout.table_name}") if layout.definition.without_rowid?
        old = read_row(layout, rowid)
        next false unless old
        delete_row(layout, old, rowid)
        true
      end
    end

    # Deletes the row of a WITHOUT ROWID table whose primary key equals
    # *key*.
    def delete(table_name : String, key : Array(Value)) : Bool
      write_statement(journal: false) do
        layout = table_layout(table_name)
        old = read_row_by_key(layout, key)
        next false unless old
        delete_row(layout, old, nil)
        true
      end
    end

    # --- Internals --------------------------------------------------------

    # Runs one write: inside a transaction as a statement that is undone
    # alone when it raises, otherwise in a transaction of its own.
    private def write_statement(*, journal : Bool = true, & : -> T) : T forall T
      if @pager.in_write_transaction? && !journal
        changes = @pager.change_count
        begin
          return yield
        rescue error
          # A failure after a page changed (out of pages, an I/O error)
          # ends the transaction, as it does in SQLite.
          @pager.rollback unless @pager.change_count == changes
          raise error
        end
      end
      if @pager.in_write_transaction?
        @pager.begin_statement
        begin
          result = yield
        rescue error
          @pager.rollback_statement
          raise error
        end
        @pager.end_statement
        return result
      end
      @pager.begin_write
      begin
        result = yield
        @pager.commit
        result
      rescue error
        @pager.rollback
        raise error
      end
    end

    # One writer while the text encoding and schema format stay the same.
    private def btree_writer : BTreeWriter
      encoding = text_encoding
      schema_format = header.try(&.schema_format) || 4_u32
      writer = @btree_writer
      return writer if writer && writer.writes?(encoding, schema_format)
      @btree_writer = BTreeWriter.new(@pager, encoding, schema_format, @btree_scratch)
    end

    @btree_writer : BTreeWriter?

    private def schema_changed : Nil
      cookie = @pager.header_field(Pager::SCHEMA_COOKIE_OFFSET)
      @pager.set_header_field(Pager::SCHEMA_COOKIE_OFFSET, cookie &+ 1)
      @schema = nil
      @table_layouts.clear
    end

    private def find_entry(name : String) : SchemaEntry?
      schema.list_of_entries.find { |entry| entry.object_name.compare(name, case_insensitive: true) == 0 }
    end

    private def check_new_name(name : String) : Nil
      raise SchemaError.new("object name reserved for internal use: #{name}") if name.downcase.starts_with?("sqlite_")
    end

    private def parse_table(sql : String) : TableDefinition
      TableDefinition.parse(sql)
    rescue error : SchemaTokenizer::Malformed
      raise SchemaError.new("malformed CREATE TABLE: #{error.message}")
    end

    # The checks sqlite3EndTable and friends make before a table exists.
    private def check_table(definition : TableDefinition) : Nil
      columns = definition.list_of_columns
      if columns.size > Limits::MAX_COLUMNS
        raise LimitExceeded.new("SQLITE_MAX_COLUMN", "table #{definition.table_name} has #{columns.size} columns, more than #{Limits::MAX_COLUMNS}")
      end
      seen = Set(String).new
      columns.each do |column|
        raise SchemaError.new("duplicate column name: #{column.column_name}") unless seen.add?(column.column_name.downcase)
        Collation.named(column.collation)
      end
      (definition.list_of_primary_key_columns + definition.list_of_unique_constraints.flatten).each do |column_name|
        raise SchemaError.new("no such column: #{column_name}") unless definition.column_index(column_name)
      end
      if definition.without_rowid? && definition.list_of_primary_key_columns.empty?
        raise SchemaError.new("PRIMARY KEY missing on table #{definition.table_name}")
      end
      if definition.autoincrement? && definition.rowid_alias_index.nil?
        raise SchemaError.new("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY")
      end
    end

    private def insert_schema_row(writer : BTreeWriter, type : String, name : String, table_name : String, root : UInt32, sql : String?) : Nil
      rowid = (writer.table_max_rowid(1_u32) || 0_i64) + 1
      values = [type, name, table_name, root.to_i64, sql] of Value
      writer.table_insert(1_u32, rowid, RecordEncoder.encode(values, text_encoding))
    end

    private def delete_schema_row(writer : BTreeWriter, entry : SchemaEntry) : Nil
      doomed = [] of Int64
      each_table_btree_record(1_u32) do |rowid, record|
        doomed << rowid if record[0]? == entry.object_type && record[1]? == entry.object_name
      end
      doomed.each { |rowid| writer.table_delete(1_u32, rowid) }
    end

    private def table_layout(table_name : String) : TableLayout
      key = table_name.downcase
      current_schema = schema
      if cached = @table_layouts[key]?
        return cached
      end
      entry = current_schema.entry(table_name)
      raise UnknownSchemaObject.new(table_name) unless entry.table? && entry.has_a_btree?
      definition = current_schema.table_definition(entry)
      indexes = current_schema.list_of_indexes.select { |index| index.table_name.compare(entry.object_name, case_insensitive: true) == 0 }
      layouts = indexes.map { |index| IndexLayout.build(index, definition, text_encoding) }
      @table_layouts[key] = TableLayout.new(entry, definition, layouts, text_encoding)
    end

    # `stored_row` in *values* itself, for an array the caller owns (a row
    # just decoded from its record).
    private def stored_row!(definition : TableDefinition, values : Array(Value)) : Array(Value)
      columns = definition.list_of_columns
      strict = definition.strict?
      values.size.times do |position|
        column = columns[position]
        value = values.unsafe_fetch(position)
        values[position] = if strict
                             StoredValue.for_strict_column(column.declared_type, "#{definition.table_name}.#{column.column_name}", value)
                           else
                             StoredValue.for_affinity(column.affinity, value)
                           end
      end
      values
    end

    # The values a row stores, column by column: STRICT type checks, or the
    # column affinity's conversion.
    private def stored_row(definition : TableDefinition, values : Array(Value)) : Array(Value)
      columns = definition.list_of_columns
      values.map_with_index do |value, position|
        column = columns[position]
        if definition.strict?
          StoredValue.for_strict_column(column.declared_type, "#{definition.table_name}.#{column.column_name}", value)
        else
          StoredValue.for_affinity(column.affinity, value)
        end
      end
    end

    private def insert_row(layout : TableLayout, rowid : Int64?, values : Array(Value), update_sequence : Bool) : Int64?
      definition = layout.definition
      columns = definition.list_of_columns
      unless values.size == columns.size
        raise ArgumentError.new("#{layout.table_name} has #{columns.size} columns; #{values.size} values were given")
      end
      if generated = columns.find { |column| !column.generated.none? }
        raise UnsupportedSQL.new("writing generated column #{layout.table_name}.#{generated.column_name}")
      end
      layout.list_of_indexes.each do |index|
        if index.needs_evaluation?
          raise UnsupportedSQL.new("writing index #{index.entry.object_name} outside a SQL session (its WHERE or expression terms)")
        end
      end
      row = stored_row(definition, values)
      alias_index = definition.rowid_alias_index
      columns.each_with_index do |column, position|
        next unless row[position].nil?
        next if position == alias_index
        if column.not_null? || primary_key_column?(layout, position)
          raise ConstraintViolation.new(ConstraintViolation::Kind::NotNull, "#{layout.table_name}.#{column.column_name}")
        end
      end
      writer = btree_writer
      if definition.without_rowid?
        raise ArgumentError.new("WITHOUT ROWID table #{layout.table_name} has no rowid") if rowid
        comparator = layout.comparator || raise Error.new("WITHOUT ROWID table #{layout.table_name} has no key order")
        record = layout.list_of_stored_positions.map { |position| row[position] }
        key_count = layout.list_of_primary_key_positions.size
        existing = writer.index_first_at_least(layout.entry.root_page, record, key_count, comparator)
        if existing && comparator.compare(existing, record, key_count) == 0
          raise ConstraintViolation.new(ConstraintViolation::Kind::PrimaryKey, key_columns_text(layout, layout.list_of_primary_key_positions))
        end
        entries = layout.list_of_indexes.map(&.entry_for(row, nil))
        layout.list_of_indexes.each_with_index { |index, position| check_unique(writer, index, layout.table_name, entries[position]) }
        writer.index_insert(layout.entry.root_page, record, comparator)
        layout.list_of_indexes.each_with_index { |index, position| writer.index_insert(index.entry.root_page, entries[position], index.comparator) }
        return
      end
      if alias_index
        alias_value = row[alias_index]
        if alias_value
          unless alias_value.is_a?(Int64)
            raise ConstraintViolation.new(ConstraintViolation::Kind::Datatype, "datatype mismatch")
          end
          raise ArgumentError.new("rowid #{rowid} differs from #{columns[alias_index].column_name} #{alias_value}") if rowid && rowid != alias_value
          rowid = alias_value
        end
      end
      rowid ||= new_rowid(writer, layout)
      row[alias_index] = rowid if alias_index
      record = RecordEncoder.encode(layout.list_of_stored_positions.map { |position| position == alias_index ? nil : row[position] }, text_encoding, writer_schema_format)
      key_name = alias_index ? columns[alias_index].column_name : "rowid"
      entries = layout.list_of_indexes.map(&.entry_for(row, rowid))
      # Every constraint is checked before the first page changes, the
      # rowid first as SQLite does, so a refused row leaves no trace.
      unless entries.empty?
        if writer.table_contains?(layout.entry.root_page, rowid)
          raise ConstraintViolation.new(ConstraintViolation::Kind::PrimaryKey, "#{layout.table_name}.#{key_name}")
        end
        layout.list_of_indexes.each_with_index { |index, position| check_unique(writer, index, layout.table_name, entries[position]) }
      end
      unless writer.table_insert_new(layout.entry.root_page, rowid, record)
        raise ConstraintViolation.new(ConstraintViolation::Kind::PrimaryKey, "#{layout.table_name}.#{key_name}")
      end
      layout.list_of_indexes.each_with_index { |index, position| writer.index_insert(index.entry.root_page, entries[position], index.comparator) }
      record_sequence(writer, layout.table_name, rowid) if update_sequence && definition.autoincrement?
      rowid
    end

    # Primary key columns may not be NULL in WITHOUT ROWID and STRICT tables
    # (withoutrowid.html §2, stricttables.html §2.2).
    private def primary_key_column?(layout : TableLayout, position : Int32) : Bool
      definition = layout.definition
      return false unless definition.without_rowid? || definition.strict?
      column_name = definition.list_of_columns[position].column_name.downcase
      definition.list_of_primary_key_columns.any? { |key| key.downcase == column_name }
    end

    private def writer_schema_format : UInt32
      header.try(&.schema_format) || 4_u32
    end

    # Raises when a UNIQUE index already holds *entry*'s key (NULLs are
    # distinct, so a key holding one never conflicts).
    private def check_unique(writer : BTreeWriter, index : IndexLayout, table_name : String, entry : Array(Value)) : Nil
      key_count = index.key_count
      if index.unique? && (0...key_count).none? { |position| entry[position].nil? }
        existing = writer.index_first_at_least(index.entry.root_page, entry, key_count, index.comparator)
        if existing && index.comparator.compare(existing, entry, key_count) == 0
          kind = index.primary_key? ? ConstraintViolation::Kind::PrimaryKey : ConstraintViolation::Kind::Unique
          raise ConstraintViolation.new(kind, "#{table_name} (index #{index.entry.object_name})")
        end
      end
    end

    private def key_columns_text(layout : TableLayout, positions : Array(Int32)) : String
      positions.map { |position| "#{layout.table_name}.#{layout.definition.list_of_columns[position].column_name}" }.join(", ")
    end

    # One past the largest rowid (one past the largest ever used, for
    # AUTOINCREMENT). When the largest is Int64::MAX, SQLite tries random
    # rowids; so does the engine.
    private def new_rowid(writer : BTreeWriter, layout : TableLayout) : Int64
      largest = writer.table_max_rowid(layout.entry.root_page)
      if layout.definition.autoincrement?
        base = Math.max(largest || 0_i64, sequence_value(layout.table_name) || 0_i64)
        raise LimitExceeded.new("AUTOINCREMENT", "#{layout.table_name} has used the largest rowid") if base == Int64::MAX
        return base + 1
      end
      return 1_i64 unless largest
      return largest + 1 if largest < Int64::MAX
      100.times do
        candidate = Random.rand(1_i64..Int64::MAX)
        return candidate unless writer.table_record(layout.entry.root_page, candidate)
      end
      raise LimitExceeded.new("rowid", "no unused rowid found in #{layout.table_name}")
    end

    private def sequence_row(table_name : String) : {Int64, Int64}?
      entry = find_entry(SEQUENCE_TABLE)
      return unless entry
      found = nil
      each_table_btree_record(entry.root_page) do |rowid, record|
        seq = record[1]?
        found = {rowid, seq.is_a?(Int64) ? seq : 0_i64} if record[0]? == table_name && found.nil?
      end
      found
    end

    private def sequence_value(table_name : String) : Int64?
      sequence_row(table_name).try(&.[1])
    end

    # Records *rowid* in sqlite_sequence when it passes the largest rowid
    # the table has used (sqlite3AutoincrementEnd).
    private def record_sequence(writer : BTreeWriter, table_name : String, rowid : Int64) : Nil
      entry = find_entry(SEQUENCE_TABLE) || raise CorruptDatabase.new("AUTOINCREMENT table #{table_name} without sqlite_sequence", 1_u32)
      existing = sequence_row(table_name)
      original = existing.try(&.[1]) || 0_i64
      return unless rowid > original
      sequence_rowid = existing.try(&.[0]) || (writer.table_max_rowid(entry.root_page) || 0_i64) + 1
      writer.table_insert(entry.root_page, sequence_rowid, RecordEncoder.encode([table_name, rowid] of Value, text_encoding))
    end

    private def delete_sequence_row(writer : BTreeWriter, table_name : String) : Nil
      entry = find_entry(SEQUENCE_TABLE)
      return unless entry
      if existing = sequence_row(table_name)
        writer.table_delete(entry.root_page, existing[0])
      end
    end

    # The stored values of the row with *rowid*, in declared order with the
    # rowid alias holding the rowid, or nil.
    private def read_row(layout : TableLayout, rowid : Int64) : Array(Value)?
      values = btree_writer.table_values(layout.entry.root_page, rowid, layout.entry.root_page)
      return unless values
      stored_row!(layout.definition, layout.row_mapping.map(rowid, values))
    end

    private def read_row_by_key(layout : TableLayout, key : Array(Value)) : Array(Value)?
      definition = layout.definition
      raise UnsupportedSQL.new("primary key lookup in rowid table #{layout.table_name}") unless definition.without_rowid?
      comparator = layout.comparator || raise Error.new("WITHOUT ROWID table #{layout.table_name} has no key order")
      positions = layout.list_of_primary_key_positions
      raise ArgumentError.new("#{layout.table_name} has a #{positions.size}-column primary key") unless key.size == positions.size
      columns = definition.list_of_columns
      # A key is matched as a WHERE clause compares a column with a value:
      # text takes the column's numeric affinity, numbers its TEXT affinity
      # (none for STRICT ANY), and nothing else is converted.
      stored_key = key.map_with_index do |value, position|
        column = columns[positions[position]]
        any = definition.strict? && column.declared_type.compare("ANY", case_insensitive: true) == 0
        any ? value : StoredValue.for_comparison(column.affinity, value)
      end
      found = btree_writer.index_first_at_least(layout.entry.root_page, stored_key, positions.size, comparator)
      return unless found && comparator.compare(found, stored_key, positions.size) == 0
      stored_row!(definition, layout.row_mapping.map(nil, found))
    end

    private def delete_row(layout : TableLayout, row : Array(Value), rowid : Int64?) : Nil
      writer = btree_writer
      layout.list_of_indexes.each do |index|
        unless writer.index_delete(index.entry.root_page, index.entry_for(row, rowid), index.comparator)
          raise CorruptDatabase.new("index #{index.entry.object_name} has no entry for a row of #{layout.table_name}", index.entry.root_page)
        end
      end
      if rowid
        writer.table_delete(layout.entry.root_page, rowid)
      else
        comparator = layout.comparator || raise Error.new("WITHOUT ROWID table #{layout.table_name} has no key order")
        record = layout.list_of_stored_positions.map { |position| row[position] }
        writer.index_delete(layout.entry.root_page, record, comparator)
      end
    end
  end
end
