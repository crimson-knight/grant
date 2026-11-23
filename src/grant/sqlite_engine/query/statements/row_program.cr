module Grant::SQLiteEngine::Query
  # A row a write statement hands to expressions under a table's name: the
  # row being inserted for CHECK, DEFAULT and RETURNING, the existing row
  # and `excluded` for an upsert. Compiled once, filled before each use.
  class PseudoTable
    getter name : String
    getter table : TableInfo
    property rowid : Int64? = nil
    property row : Array(Value) = [] of Value
    # Reached only by a qualified name (`excluded.x`), as C's upsert
    # pseudo-table is.
    property? qualified_only = false

    def initialize(@name : String, @table : TableInfo)
    end
  end

  # Reads the one row its PseudoTable holds.
  class PseudoRowSource < RowSource
    @done = false

    def initialize(@slot : Int32, @pseudo : PseudoTable)
    end

    def open(frame : Frame) : Nil
      @done = false
    end

    def advance(frame : Frame) : Bool
      return false if @done
      @done = true
      frame.list_of_rows[@slot] = @pseudo.row
      frame.list_of_rowids[@slot] = @pseudo.rowid
      true
    end
  end

  class Compiler
    # Tables a write statement substitutes by name (lower case).
    getter pseudo_tables = {} of String => PseudoTable
    # The table whose top-level FROM entry a write statement reads rows
    # from (UPDATE, DELETE): its slot is captured while compiling.
    property capture_name : String? = nil
    getter captured_slot : Int32? = nil

    private def compile_table_reference(reference : SQL::TableReference, context : QueryContext) : {FromEntry, RowSource}
      if reference.schema.nil? && (pseudo = @pseudo_tables[reference.name.value.downcase]?)
        slot = allocate_slot
        table = pseudo.table
        columns = (0...table.list_of_column_names.size).map do |index|
          SourceColumn.new(table.list_of_column_names[index], table.list_of_affinities[index], table.list_of_collations[index])
        end
        entry = FromEntry.new(reference.alias_name.try(&.value) || pseudo.name, slot, columns, table)
        entry.not_indexed = true
        if pseudo.qualified_only?
          columns.size.times { |index| entry.merged_columns << index }
        end
        return {entry, PseudoRowSource.new(slot, pseudo).as(RowSource)}
      end
      result = previous_def
      if (name = @capture_name) && @captured_slot.nil? && context.parent.nil? &&
         reference.name.value.compare(name, case_insensitive: true) == 0
        @captured_slot = result[0].slot
      end
      result
    end

    # The root page of the index the captured table is read through (nil:
    # the table b-tree, in rowid order).
    getter captured_index_root : UInt32? = nil

    private def choose_access(step : JoinStep, terms : Array(Expr), available : Set(Int32), context : QueryContext) : RowSource
      return step.base_source if step.base_source.is_a?(PseudoRowSource)
      source = previous_def
      if source.is_a?(IndexLookupSource) && source.slot == @captured_slot
        @captured_index_root = source.root_page
      end
      source
    end

    private def simple_count_table(core : SQL::SelectClause, steps : Array(JoinStep), order_by : Array(SQL::OrderingTerm)) : TableInfo?
      return if steps.any?(&.base_source.is_a?(PseudoRowSource))
      previous_def
    end
  end

  # Expressions compiled as the result columns of a SELECT over pseudo
  # tables, evaluated against whatever rows those tables hold: CHECK
  # constraints, DEFAULT values, generated columns, RETURNING, an upsert's
  # SET and WHERE, a partial index's WHERE.
  class RowProgram
    getter list_of_column_names : Array(String)
    getter list_of_pseudo_tables : Array(PseudoTable)

    @compiled : CompiledSelect

    # *columns* are the result columns; *where*, when given, filters (an
    # evaluation the WHERE rejects returns nil).
    def initialize(@session : Session, columns : Array(SQL::ResultColumn), @list_of_pseudo_tables : Array(PseudoTable),
                   where : SQL::Expression? = nil)
      items = @list_of_pseudo_tables.map_with_index do |pseudo, index|
        join = index == 0 ? nil : SQL::JoinOperator.new(true, [] of String)
        SQL::FromItem.new(join, SQL::TableReference.new(nil, SQL::Name.bare(pseudo.name), nil, nil, false), nil, nil)
      end
      from = items.empty? ? nil : SQL::From.new(items)
      core = SQL::SelectClause.new(SQL::DistinctMode::None, columns, from, where, [] of SQL::Expression, nil,
        [] of SQL::WindowDefinition)
      statement = SQL::SelectStatement.new(nil, [core] of SQL::SelectCore, [] of SQL::CompoundOperator,
        [] of SQL::OrderingTerm, nil)
      compiler = Compiler.new(@session)
      @list_of_pseudo_tables.each { |pseudo| compiler.pseudo_tables[pseudo.name.downcase] = pseudo }
      @compiled = compiler.compile(statement)
      @list_of_column_names = @compiled.list_of_column_names
    end

    # Expressions as result columns.
    def self.columns(list_of_expressions : Array(SQL::Expression)) : Array(SQL::ResultColumn)
      list_of_expressions.map { |expression| SQL::ExpressionColumn.new(expression, nil).as(SQL::ResultColumn) }
    end

    # The values of the result columns for the rows the pseudo tables hold
    # now, or nil when the WHERE rejects them.
    def evaluate(list_of_parameters : Array(Value)) : Array(Value)?
      frame = Frame.new(@compiled.slot_count, @compiled.aggregate_count, list_of_parameters, @session)
      producer = @compiled.producer
      producer.open(frame)
      producer.next_row(frame)
    end
  end
end

module Grant::SQLiteEngine::Query
  class IndexLookupSource
    # The frame slot and index b-tree of the rows it reads (for a write
    # statement's row order).
    getter slot : Int32
    getter root_page : UInt32
  end
end
