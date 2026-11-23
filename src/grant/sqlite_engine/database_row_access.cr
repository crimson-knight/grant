module Grant::SQLiteEngine
  # Row-level access for the SQL write statements (`Query::Statements`):
  # they decide what to write and in which order, the way SQLite's INSERT,
  # UPDATE and DELETE code does, and call these to probe constraints and
  # change b-trees. Every method expects an open write transaction.
  class Database
    # The writer's view of *table_name*.
    def write_layout(table_name : String) : TableLayout
      table_layout(table_name)
    end

    # The b-tree writer of the open transaction.
    def tree_writer : BTreeWriter
      btree_writer
    end

    # The values *definition* stores for *values* (declared order): the
    # column affinities applied, or a STRICT table's type checks.
    def stored_values(definition : TableDefinition, values : Array(Value)) : Array(Value)
      stored_row(definition, values)
    end

    # True when the rowid table holds a row with *rowid*.
    def row_exists?(layout : TableLayout, rowid : Int64) : Bool
      btree_writer.table_contains?(layout.entry.root_page, rowid)
    end

    # The row with *rowid* in declared order, or nil.
    def row_at(layout : TableLayout, rowid : Int64) : Array(Value)?
      read_row(layout, rowid)
    end

    # The row of a WITHOUT ROWID table whose primary key equals the key
    # columns of *values* (declared order), or nil.
    def row_with_key_of(layout : TableLayout, values : Array(Value)) : Array(Value)?
      comparator = layout.comparator || raise Error.new("WITHOUT ROWID table #{layout.table_name} has no key order")
      record = layout.list_of_stored_positions.map { |position| values[position] }
      key_count = layout.list_of_primary_key_positions.size
      found = btree_writer.index_first_at_least(layout.entry.root_page, record, key_count, comparator)
      return unless found && comparator.compare(found, record, key_count) == 0
      stored_row(layout.definition, RowMapping.new(layout.table_name, layout.definition).map(nil, found))
    end

    # The existing entry of *index* whose key equals *entry*'s key, or nil.
    # NULLs are distinct, so a key holding one matches nothing.
    def index_entry_matching(index : IndexLayout, entry : Array(Value)) : Array(Value)?
      key_count = index.key_count
      return if (0...key_count).any? { |position| entry[position].nil? }
      existing = btree_writer.index_first_at_least(index.entry.root_page, entry, key_count, index.comparator)
      return unless existing && index.comparator.compare(existing, entry, key_count) == 0
      existing
    end

    # The rowid C would give a new row (OP_NewRowid): one past the largest,
    # or past the largest ever used for AUTOINCREMENT, with *floor* (the
    # largest rowid this statement inserted) taken into account.
    def next_rowid(layout : TableLayout, floor : Int64? = nil) : Int64
      if layout.definition.autoincrement? && floor
        largest = btree_writer.table_max_rowid(layout.entry.root_page) || 0_i64
        base = Math.max(Math.max(largest, floor), sequence_value(layout.table_name) || 0_i64)
        raise SQLError.new("database or disk is full", 13) if base == Int64::MAX
        return base + 1
      end
      new_rowid(btree_writer, layout)
    end

    # The sqlite_sequence value of *table_name*, or nil.
    def sequence_of(table_name : String) : Int64?
      sequence_value(table_name)
    end

    # Writes *value* as *table_name*'s sqlite_sequence value, adding the row
    # when the table has none (sqlite3AutoincrementEnd).
    def write_sequence(table_name : String, value : Int64) : Nil
      writer = btree_writer
      entry = find_entry(SEQUENCE_TABLE) || raise CorruptDatabase.new("AUTOINCREMENT table #{table_name} without sqlite_sequence", 1_u32)
      existing = sequence_row(table_name)
      sequence_rowid = existing.try(&.[0]) || (writer.table_max_rowid(entry.root_page) || 0_i64) + 1
      writer.table_insert(entry.root_page, sequence_rowid, RecordEncoder.encode([table_name, value] of Value, text_encoding))
    end

    # Writes the row (declared order, values already stored as the column
    # affinities have them) and its index entries. *rowid* is nil for a
    # WITHOUT ROWID table. An existing row with the same rowid is replaced
    # in the table b-tree; the caller removed its index entries.
    #
    # *list_of_entries* pairs each index that holds the row with its entry.
    def write_row(layout : TableLayout, rowid : Int64?, row : Array(Value), list_of_entries : Array({IndexLayout, Array(Value)})) : Nil
      writer = btree_writer
      if rowid
        alias_index = layout.definition.rowid_alias_index
        record = RecordEncoder.encode(layout.list_of_stored_positions.map { |position| position == alias_index ? nil : row[position] },
          text_encoding, writer_schema_format)
        writer.table_insert(layout.entry.root_page, rowid, record)
      else
        comparator = layout.comparator || raise Error.new("WITHOUT ROWID table #{layout.table_name} has no key order")
        writer.index_insert(layout.entry.root_page, layout.list_of_stored_positions.map { |position| row[position] }, comparator)
      end
      list_of_entries.each do |index, entry|
        writer.index_insert(index.entry.root_page, entry, index.comparator)
      end
    end

    # Removes the row (declared order, as stored) and its index entries
    # (*list_of_entries*: each index that holds it with its entry).
    def remove_row(layout : TableLayout, rowid : Int64?, row : Array(Value), list_of_entries : Array({IndexLayout, Array(Value)})) : Nil
      writer = btree_writer
      list_of_entries.each do |index, entry|
        unless writer.index_delete(index.entry.root_page, entry, index.comparator)
          raise CorruptDatabase.new("index #{index.entry.object_name} has no entry for a row of #{layout.table_name}", index.entry.root_page)
        end
      end
      if rowid
        writer.table_delete(layout.entry.root_page, rowid)
      else
        comparator = layout.comparator || raise Error.new("WITHOUT ROWID table #{layout.table_name} has no key order")
        writer.index_delete(layout.entry.root_page, layout.list_of_stored_positions.map { |position| row[position] }, comparator)
      end
    end

    # Removes the index entries of the row only (REPLACE of a conflicting
    # rowid: the table entry is overwritten by the new row).
    def remove_index_entries(list_of_entries : Array({IndexLayout, Array(Value)})) : Nil
      writer = btree_writer
      list_of_entries.each do |index, entry|
        writer.index_delete(index.entry.root_page, entry, index.comparator)
      end
    end

    # Adds a schema row as SQLite does (the next rowid of sqlite_schema).
    def add_schema_row(type : String, name : String, table_name : String, root : UInt32, sql : String?) : Nil
      insert_schema_row(btree_writer, type, name, table_name, root, sql)
    end

    # Replaces the sql column (and names) of the schema rows the block
    # changes: it receives each row's values (type, name, tbl_name,
    # rootpage, sql) and returns the new values or nil to keep the row.
    def rewrite_schema_rows(& : Array(Value) -> Array(Value)?) : Nil
      writer = btree_writer
      changes = [] of {Int64, Array(Value)}
      each_table_btree_record(1_u32) do |rowid, record|
        if replacement = yield record
          changes << {rowid, replacement}
        end
      end
      changes.each do |rowid, values|
        writer.table_insert(1_u32, rowid, RecordEncoder.encode(values, text_encoding))
      end
      schema_changed unless changes.empty?
    end

    # Deletes the schema rows the block selects.
    def delete_schema_rows(& : Array(Value) -> Bool) : Nil
      writer = btree_writer
      doomed = [] of Int64
      each_table_btree_record(1_u32) do |rowid, record|
        doomed << rowid if yield record
      end
      doomed.each { |rowid| writer.table_delete(1_u32, rowid) }
      schema_changed unless doomed.empty?
    end

    # Marks the schema as changed: the cookie moves on and cached layouts go.
    def note_schema_change : Nil
      schema_changed
    end

    # Forgets cached table layouts (after a rollback).
    def forget_layouts : Nil
      @table_layouts.clear
      @schema = nil
    end

    # Empties the b-tree at *root*, keeping the root page (OP_Clear).
    def clear_tree(root : UInt32, table : Bool) : Nil
      writer = btree_writer
      writer.free_tree(root)
      fresh = writer.create_tree(table: table)
      return if fresh == root
      # free_tree released the root too; the new tree took a page from the
      # freelist. Move its (empty) content back to the original root.
      buffer = @pager.page_for_write(root)
      buffer.fill(0_u8)
      PageEditor.new(buffer, root, @pager.usable_size).initialize_page(table ? PageType::LeafTable : PageType::LeafIndex)
      @pager.free_page(fresh)
    end

    # Writes header field *offset* (user_version, application_id).
    def write_header_field(offset : Int32, value : UInt32) : Nil
      @pager.set_header_field(offset, value)
    end

    # Every collation an index names must exist ("no such collation sequence").
    private def check_collations(definition : IndexDefinition) : Nil
      definition.list_of_key_terms.each do |term|
        if collation = term.collation
          Collation.named(collation)
        end
      end
    end

    # CREATE INDEX inside a write statement: the index is filled from the
    # table's rows (only those a partial index's WHERE accepts) and a
    # UNIQUE index with two equal keys fails with C's message.
    def create_index_from(sql : String, run : Query::WriteRun) : Nil
      statement = CreateStatement.index(sql)
      name = statement.object_name
      table_name = statement.table_name || raise SchemaError.new("CREATE INDEX names no table")
      table_entry = find_entry(table_name)
      raise SchemaError.new("no such table: main.#{table_name}") unless table_entry && table_entry.table? && table_entry.has_a_btree?
      table = schema.table_definition(table_entry)
      check_collations(IndexDefinition.parse(sql))
      writer = btree_writer
      root = writer.create_tree(table: false)
      insert_schema_row(writer, "index", name, table_entry.object_name, root, statement.stored_sql)
      layout = IndexLayout.build(SchemaEntry.new("index", name, table_entry.object_name, root, statement.stored_sql), table, text_encoding)
      schema_changed
      run.session.reset_schema
      write_table = run.table(table_entry.object_name, run.session.schema_name_of(self))
      rule = write_table.list_of_indexes.find { |candidate| candidate.layout.entry.object_name == name }
      # Expression terms resolve against the table now, as
      # sqlite3ResolveSelfReference does, even when it holds no rows.
      run.check_index_expressions(write_table, rule) if rule
      rows = [] of {Int64?, Array(Value)}
      run.cursor_rows(write_table) { |rowid, row| rows << {rowid, row} }
      rows.each do |rowid, row|
        values = stored_row(table, row)
        next if rule && !run.index_includes?(write_table, rule.layout, values, rowid)
        entry = rule ? run.index_entry(write_table, rule.layout, values, rowid) : layout.entry_for(values, rowid)
        if layout.unique? && index_entry_matching(layout, entry)
          raise Query::ConstraintError.new(rule ? run.unique_message(rule) : "UNIQUE constraint failed: #{name}")
        end
        writer.index_insert(root, entry, layout.comparator)
      end
    end
  end
end
