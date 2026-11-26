module Grant::SQLiteEngine::Query
  # A table as the query compiler sees it: its columns with their names,
  # affinities and collations, the rowid alias, its indexes, and how a
  # stored record becomes a row in declared column order.
  class TableInfo
    getter entry : SchemaEntry
    getter definition : TableDefinition
    getter list_of_column_names : Array(String)
    getter list_of_affinities : Array(ExpressionAffinity)
    getter list_of_collations : Array(Collation)
    getter list_of_indexes : Array(IndexLayout)
    # The database holding the table: the main file, or the connection's
    # temp database.
    getter database : Database

    @stored_order : Array(Int32)
    @in_place : Bool
    @real_columns : Array(Int32)

    def initialize(@entry : SchemaEntry, @definition : TableDefinition, @list_of_indexes : Array(IndexLayout), @database : Database)
      columns = @definition.list_of_columns
      @list_of_column_names = columns.map(&.column_name)
      @list_of_affinities = columns.map { |column| ExpressionAffinity.from(column.affinity) }
      @list_of_collations = columns.map { |column| Collation.named?(column.collation) || Collation::Binary }
      @stored_order = @definition.stored_column_order
      @in_place = !@definition.without_rowid? && @stored_order == (0...columns.size).to_a
      @real_columns = (0...columns.size).select { |index| columns[index].affinity.real? }
    end

    # The columns as a FROM entry naming the table reads them, built on
    # first use and shared by every such entry (nothing changes them).
    getter(list_of_source_columns : Array(SourceColumn)) do
      (0...@list_of_column_names.size).map do |index|
        SourceColumn.new(@list_of_column_names[index], @list_of_affinities[index], @list_of_collations[index])
      end
    end

    @unsupported : String? = nil

    def name : String
      @entry.object_name
    end

    def root_page : UInt32
      @entry.root_page
    end

    def without_rowid? : Bool
      @definition.without_rowid?
    end

    def rowid_alias : Int32?
      @definition.rowid_alias_index
    end

    def column_index(column_name : String) : Int32?
      @list_of_column_names.index { |candidate| candidate.compare(column_name, case_insensitive: true) == 0 }
    end

    # Raises when rows of the table cannot be read yet.
    def check_readable : Nil
      if reason = @unsupported
        raise UnsupportedSQL.new(reason)
      end
    end

    # The row in declared column order from a stored record: the rowid in
    # the alias column, REAL affinity restored on whole numbers SQLite
    # stored as integers, and DEFAULT values for columns the record
    # predates.
    def row_from(rowid : Int64?, record : Array(Value)) : Array(Value)
      count = @list_of_column_names.size
      if @in_place && record.size == count
        @real_columns.each do |column_index|
          value = record.unsafe_fetch(column_index)
          record[column_index] = value.to_f64 if value.is_a?(Int64)
        end
        if (alias_index = rowid_alias) && rowid
          record[alias_index] = rowid
        end
        return record
      end
      values = Array(Value).new(count, nil)
      columns = @definition.list_of_columns
      @stored_order.each_with_index do |column_index, position|
        column = columns[column_index]
        values[column_index] = if position < record.size
                                 stored = record.unsafe_fetch(position)
                                 stored.is_a?(Int64) && column.affinity.real? ? stored.to_f64 : stored
                               else
                                 default_for(column)
                               end
      end
      if (alias_index = rowid_alias) && rowid
        values[alias_index] = rowid
      end
      values
    end

    # The stored record position of declared column *column_index*.
    def stored_position(column_index : Int32) : Int32?
      @stored_order.index(column_index)
    end

    # The stored record positions holding the columns *use* includes.
    def stored_mask_for(use : ColumnUse) : Array(Bool)
      mask = Array(Bool).new(@stored_order.size, false)
      @stored_order.each_with_index do |column_index, position|
        mask[position] = true if use.includes?(column_index)
      end
      mask
    end

    # The stored record positions holding *columns* (declared indexes; nil
    # for every column).
    def stored_mask_for(columns : Set(Int32)?) : Array(Bool)
      mask = Array(Bool).new(@stored_order.size, false)
      @stored_order.each_with_index do |column_index, position|
        mask[position] = true if columns.nil? || columns.includes?(column_index)
      end
      mask
    end

    # The row in declared column order from a stored record, decoding only
    # the columns *use* marks (the others read NULL, and nothing reads
    # them), written into *into* (a source reuses one array per row, so
    # whatever keeps a row past the next one copies it). Otherwise as
    # `row_from`.
    def decode_row(rowid : Int64, header : RecordHeader, encoding : TextEncoding, use : ColumnUse,
                   into values : Array(Value)) : Array(Value)
      # The columns *use* marks are written for every row and no other
      # column is written, so the array needs clearing only when its size
      # is wrong.
      clear_row(values) unless values.size == @list_of_column_names.size
      fill_columns(header, rowid, use.stored_positions(self), encoding, values)
      values
    end

    # Empties *values* to one NULL per column, ready for `fill_columns`.
    def clear_row(values : Array(Value)) : Nil
      count = @list_of_column_names.size
      if values.size == count
        values.fill(nil)
      else
        values.clear
        count.times { values << nil }
      end
    end

    # Writes the columns at stored *positions* from the record *header*
    # into *values* (one slot per column), as `decode_row` does, and the
    # rowid alias.
    def fill_columns(header : RecordHeader, rowid : Int64, positions : Array(Int32), encoding : TextEncoding,
                     values : Array(Value)) : Nil
      stored_order = @stored_order
      positions.each do |position|
        column_index = stored_order.unsafe_fetch(position)
        if header.has?(position)
          value = header.value(position, encoding)
          value = value.to_f64 if value.is_a?(Int64) && @list_of_affinities.unsafe_fetch(column_index).real?
        else
          value = default_for(@definition.list_of_columns[column_index])
        end
        values.unsafe_put(column_index, value)
      end
      if alias_index = rowid_alias
        values.unsafe_put(alias_index, rowid)
      end
    end

    # The row from an index entry whose key columns sit at table column
    # *positions*; the caller reads no other column.
    def row_from_index(rowid : Int64, entry : Array(Value), positions : Array(Int32), into values : Array(Value)) : Array(Value)
      # The caller reads only the key columns, which are written for every
      # entry, so the array needs clearing only when its size is wrong.
      clear_row(values) unless values.size == @list_of_column_names.size
      positions.each_with_index do |column_index, key_index|
        value = entry[key_index]?
        value = value.to_f64 if value.is_a?(Int64) && @list_of_affinities.unsafe_fetch(column_index).real?
        values[column_index] = value
      end
      if alias_index = rowid_alias
        values[alias_index] = rowid
      end
      values
    end

    private def default_for(column : ColumnDefinition) : Value
      if expression = column.default_expression
        raise UnsupportedSQL.new("DEFAULT #{expression} of #{name}.#{column.column_name} for a row written before the column was added")
      end
      literal = column.default_real_literal
      return literal if literal && column.affinity.text?
      if column.default_negated_text?
        negated = ValueSemantics.arithmetic(ValueSemantics::Arithmetic::Subtract, 0_i64, column.default_value)
        return column.affinity.apply(negated)
      end
      column.affinity.apply(column.default_value)
    end
  end
end
