module Grant::SQLiteEngine
  # How the writer builds and orders the entries of one index of a table
  # (fileformat2.html §2.5, sqlite3CreateIndex): the table columns of its key
  # terms, the columns appended after them (the rowid, or the primary key
  # columns of a WITHOUT ROWID table that the key does not already hold
  # with the same collation), each column's collation and order, and
  # whether two rows may share a key.
  class IndexLayout
    getter entry : SchemaEntry
    getter list_of_key_positions : Array(Int32)
    getter list_of_tail_positions : Array(Int32)
    getter comparator : KeyComparator
    getter? unique : Bool
    getter? primary_key : Bool
    # Why the index cannot be maintained without evaluating SQL (an
    # expression key or a WHERE clause), or nil.
    getter unsupported_reason : String?

    def initialize(@entry : SchemaEntry, @list_of_key_positions : Array(Int32), @list_of_tail_positions : Array(Int32),
                   @comparator : KeyComparator, @unique : Bool, @primary_key : Bool, @unsupported_reason : String?)
    end

    # Number of key terms; two entries with equal key terms conflict in a
    # UNIQUE index unless one of them holds a NULL.
    def key_count : Int32
      @list_of_key_positions.size
    end

    # The entry for a row: *values* are the row's columns in declared order
    # (the rowid alias holding the rowid) and *rowid* is nil for a WITHOUT
    # ROWID table.
    def entry_for(values : Array(Value), rowid : Int64?) : Array(Value)
      key = Array(Value).new(@list_of_key_positions.size + @list_of_tail_positions.size + 1)
      @list_of_key_positions.each { |position| key << values[position] }
      @list_of_tail_positions.each { |position| key << values[position] }
      key << rowid if rowid
      key
    end

    # The key columns of the primary key of a WITHOUT ROWID table: position,
    # collation and order of each.
    def self.primary_key_columns(table : TableDefinition) : Array({Int32, KeyColumn})
      terms = primary_key_terms(table)
      table.primary_key_positions.map do |position|
        column_name = table.list_of_primary_key_columns[position]
        index = table.column_index(column_name) || raise SchemaError.new("primary key names missing column #{column_name}")
        descending = terms.try { |list| list[position]?.try(&.descending) } || false
        {index, KeyColumn.new(Collation.named(table.primary_key_collation(position)), descending)}
      end
    end

    private def self.primary_key_terms(table : TableDefinition) : Array(IndexDefinition::KeyTerm)?
      wanted = table.list_of_primary_key_columns.map(&.downcase)
      position = table.list_of_unique_constraints.index { |columns| columns.map(&.downcase) == wanted }
      position ? table.list_of_unique_constraint_terms[position]? : nil
    end

    # The layout of the index *entry* of *table*.
    def self.build(entry : SchemaEntry, table : TableDefinition, encoding : TextEncoding) : IndexLayout
      terms, unique, partial = key_terms(entry, table)
      reason = partial ? "partial index #{entry.object_name} (its WHERE clause)" : nil
      positions = [] of Int32
      columns = [] of KeyColumn
      terms.each do |term|
        column_name = term.column_name
        index = column_name ? table.column_index(column_name) : nil
        unless index
          reason ||= "expression in index #{entry.object_name}"
          positions << 0
          columns << KeyColumn.new(Collation::Binary, term.descending)
          next
        end
        collation = term.collation || table.list_of_columns[index].collation
        positions << index
        columns << KeyColumn.new(Collation.named(collation), term.descending)
      end
      tail = [] of Int32
      if table.without_rowid?
        primary_key_columns(table).each do |position, key_column|
          held = positions.each_with_index.any? { |held_position, term_index| held_position == position && columns[term_index].collation == key_column.collation }
          next if held
          tail << position
          # The automatic index of a UNIQUE constraint gets the key columns
          # in ascending order whatever the key declares (build.c,
          # convertToWithoutRowidTable, "bAscKeyBug", ticket bba7b69f9849b5bf);
          # CREATE INDEX copies the declared order.
          columns << (entry.sql.nil? ? KeyColumn.new(key_column.collation, false) : key_column)
        end
      end
      primary = entry.sql.nil? && same_columns?(terms, table.list_of_primary_key_columns)
      new(entry, positions, tail, KeyComparator.new(columns, encoding), unique, primary, reason)
    end

    private def self.same_columns?(terms : Array(IndexDefinition::KeyTerm), names : Array(String)) : Bool
      terms.size == names.size && terms.zip(names).all? { |term, name| term.column_name.try(&.downcase) == name.downcase }
    end

    private def self.key_terms(entry : SchemaEntry, table : TableDefinition) : {Array(IndexDefinition::KeyTerm), Bool, Bool}
      if sql = entry.sql
        definition = IndexDefinition.parse(sql)
        return {definition.list_of_key_terms, definition.unique?, definition.partial?}
      end
      number = entry.object_name.rpartition('_').last.to_i?
      terms = number && number > 0 ? table.list_of_unique_constraint_terms[number - 1]? : nil
      raise CorruptDatabase.new("automatic index #{entry.object_name} matches no constraint of #{table.table_name}", 1_u32) unless terms
      {terms, true, false}
    end
  end
end
