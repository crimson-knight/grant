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
      if virtual = columns.find(&.generated.virtual?)
        @unsupported = "VIRTUAL generated column #{name}.#{virtual.column_name}"
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

    private def default_for(column : ColumnDefinition) : Value
      if expression = column.default_expression
        raise UnsupportedSQL.new("DEFAULT #{expression} of #{name}.#{column.column_name} for a row written before the column was added")
      end
      literal = column.default_real_literal
      return literal if literal && column.affinity.text?
      column.affinity.apply(column.default_value)
    end
  end
end
