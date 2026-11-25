module Grant::SQLiteEngine::Query
  class TableInfo
    # Per declared column, the expression of its `AS (...)` clause (nil for
    # an ordinary column), read from the CREATE TABLE text.
    getter list_of_generated_expressions : Array(SQL::Expression?) do
      list = Array(SQL::Expression?).new(@list_of_column_names.size, nil)
      sql = @entry.sql
      statement = sql ? SQL::Parser.parse_schema(sql) : nil
      if statement.is_a?(SQL::CreateTable)
        statement.columns.each_with_index do |column, index|
          break if index >= list.size
          column.constraints.each do |constraint|
            list[index] = constraint.expression if constraint.is_a?(SQL::GeneratedConstraint)
          end
        end
      end
      list
    end

    # True when a record of the table leaves out the column at
    # *column_index*: a VIRTUAL generated column, computed when it is read.
    def virtual_column?(column_index : Int32) : Bool
      @definition.list_of_columns[column_index].generated.virtual?
    end

    def has_virtual_columns? : Bool
      @definition.list_of_columns.any?(&.generated.virtual?)
    end
  end

  # A VIRTUAL generated column of the row in *slot*: its expression
  # evaluated against that row, then the column's affinity applied (or a
  # STRICT table's type check), as sqlite3ExprCodeGeneratedColumn codes it.
  # To the planner it is the column it stands for, so an index on the
  # column serves it; `children` holds the expression, whose columns are
  # the ones the row source must decode.
  class VirtualColumnExpr < ColumnExpr
    def initialize(column : ColumnExpr, @generated : Expr, @definition : ColumnDefinition, @table_name : String,
                   @strict : Bool)
      super(column.slot, column.column, column.column_affinity, column.column_collation, column.declared_name)
    end

    def evaluate(frame : Frame) : Value
      # OP_IfNullRow: the NULL row of a LEFT JOIN reads NULL whatever the
      # expression makes of NULL operands.
      return if frame.list_of_rows.unsafe_fetch(@slot).empty?
      # 'now', localtime and utc are refused here as in a STORED column.
      session = frame.session
      outer_context = session.deterministic_context
      session.deterministic_context = "a generated column"
      value = begin
        @generated.evaluate(frame)
      ensure
        session.deterministic_context = outer_context
      end
      VirtualColumnExpr.converted(value, @definition, @table_name, @strict)
    end

    def children : Array(Expr)
      [@generated] of Expr
    end

    # *value* as the generated column *definition* holds it: OP_TypeCheck
    # for a VIRTUAL column of a STRICT table, OP_Affinity otherwise. A
    # VIRTUAL column of REAL affinity reads a real (a STORED one keeps the
    # integer its record stores for a whole number).
    def self.converted(value : Value, definition : ColumnDefinition, table_name : String, strict : Bool) : Value
      virtual = definition.generated.virtual?
      converted = if strict && virtual
                    strictly_typed(value, definition, table_name)
                  else
                    StoredValue.for_affinity(definition.affinity, value)
                  end
      return converted.to_f64 if virtual && converted.is_a?(Int64) && definition.affinity.real?
      converted
    end

    private def self.strictly_typed(value : Value, definition : ColumnDefinition, table_name : String) : Value
      StoredValue.for_strict_column(definition.declared_type, definition.column_name, value)
    rescue ConstraintViolation
      # The message names the type the value has once the column's
      # affinity is applied; vdbeMemTypeName calls an integer "INT".
      refused = StoredValue.for_affinity(definition.affinity, value)
      type_name = refused.is_a?(Int64) ? "INT" : ValueSemantics.type_name(refused).upcase
      raise ConstraintError.new(
        "cannot store #{type_name} value in #{definition.declared_type.upcase} column #{table_name}.#{definition.column_name}")
    end
  end

  class Compiler
    # The virtual columns whose expressions are being compiled, as
    # {slot, column}: a column met again inside its own expression is a
    # loop (COLFLAG_BUSY).
    @virtual_columns_in_progress = Set({Int32, Int32}).new

    protected def column_expression(entry : FromEntry, index : Int32) : Expr
      plain = previous_def
      table = entry.table
      return plain unless table && plain.is_a?(ColumnExpr) && index < table.list_of_column_names.size
      return plain unless table.virtual_column?(index)
      expression = table.list_of_generated_expressions[index]
      return plain unless expression
      key = {entry.slot, index}
      if @virtual_columns_in_progress.includes?(key)
        raise SQLError.new(%(generated column loop on "#{table.list_of_column_names[index]}"))
      end
      @virtual_columns_in_progress << key
      begin
        generated = compile_row_expression(entry, table, expression)
      ensure
        @virtual_columns_in_progress.delete(key)
      end
      VirtualColumnExpr.new(plain, generated, table.definition.list_of_columns[index], table.name, table.definition.strict?)
    end

    # Compiles *expression*, whose names are columns of *table*, against
    # the row *entry* holds, and marks the columns it reads as read from
    # *entry*. The names resolve as in the CREATE TABLE: against the table
    # alone, whatever a join merged or an alias hides in *entry*.
    private def compile_row_expression(entry : FromEntry, table : TableInfo, expression : SQL::Expression) : Expr
      own = FromEntry.new(table.name, entry.slot, entry.list_of_columns, table, database: entry.database)
      context = QueryContext.new(nil, entry.slot, nil)
      context.list_of_entries << own
      compiled = compile_expression(expression, context)
      entry.list_of_columns.size.times do |column|
        entry.column_use.mark(column) if own.column_use.includes?(column)
      end
      compiled
    end

    # The columns of *table* (declared positions) a generated column's
    # *expression* reads, with the columns its VIRTUAL columns read.
    def columns_read_by(table : TableInfo, expression : SQL::Expression) : Set(Int32)
      list_of_columns = (0...table.list_of_column_names.size).map do |index|
        SourceColumn.new(table.list_of_column_names[index], table.list_of_affinities[index], table.list_of_collations[index])
      end
      entry = FromEntry.new(table.name, allocate_slot, list_of_columns, table)
      compile_row_expression(entry, table, expression)
      (0...list_of_columns.size).select { |column| entry.column_use.includes?(column) }.to_set
    end
  end
end
