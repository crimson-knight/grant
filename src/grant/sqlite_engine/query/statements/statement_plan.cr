module Grant::SQLiteEngine::Query
  # A compiled statement other than SELECT. `run` executes it once with the
  # bound parameters and returns the rows it reports (RETURNING, or a
  # PRAGMA's result); `PreparedQuery` hands them out a row at a time.
  abstract class StatementPlan
    getter list_of_column_names = [] of String

    abstract def run(list_of_parameters : Array(Value)) : Array(Array(Value))

    # The schema generation the plan was compiled against; a plan older
    # than the session's schema is compiled again before it runs.
    property schema_generation = 0

    # What the plan learned about its statement journal and row order for
    # one setting of PRAGMA foreign_keys, the only input to those choices
    # that changes without the schema (whose change compiles the plan
    # again): worked out on the first run, not on every run.
    @journal_choices : Tuple(Bool, Bool, Bool)? = nil
    @journal_choices_foreign_keys = false

    protected def journal_choices(foreign_keys : Bool, & : -> Tuple(Bool, Bool, Bool)) : Tuple(Bool, Bool, Bool)
      choices = @journal_choices
      return choices if choices && @journal_choices_foreign_keys == foreign_keys
      @journal_choices_foreign_keys = foreign_keys
      @journal_choices = yield
    end
  end

  # Names a write statement may use for the rowid of a table that has no
  # column with that name.
  module RowidName
    def self.rowid?(table : TableInfo, name : String) : Bool
      ExpressionCompiler::ROWID_NAMES.includes?(name.downcase) && table.column_index(name).nil?
    end
  end

  # One UPDATE-style SET list compiled against a table: the positions
  # assigned (-1 for the rowid) and the value expressions in the same
  # order. A later assignment to a column replaces an earlier one.
  struct AssignmentList
    getter list_of_positions : Array(Int32)
    getter list_of_expressions : Array(SQL::Expression)

    def initialize(@list_of_positions : Array(Int32), @list_of_expressions : Array(SQL::Expression))
    end

    def self.compile(table : TableInfo, assignments : Array(SQL::Assignment), generated : Set(Int32)) : AssignmentList
      positions = [] of Int32
      expressions = [] of SQL::Expression
      assignments.each do |assignment|
        values = if assignment.columns.size > 1 || assignment.parenthesized
                   value = assignment.value
                   if value.is_a?(SQL::RowValue)
                     if value.elements.size != assignment.columns.size
                       raise SQLError.new("#{assignment.columns.size} columns assigned #{value.elements.size} values")
                     end
                     value.elements
                   elsif assignment.columns.size == 1
                     [value]
                   else
                     raise UnsupportedSQL.new("row-value subquery in a SET clause")
                   end
                 else
                   [assignment.value]
                 end
        assignment.columns.each_with_index do |column, offset|
          position = table.column_index(column.value)
          if position.nil?
            raise SQLError.new("no such column: #{column.value}") if !RowidName.rowid?(table, column.value) || table.without_rowid?
            position = table.rowid_alias || -1
          end
          if generated.includes?(position)
            raise SQLError.new(%(cannot UPDATE generated column "#{table.list_of_column_names[position]}"))
          end
          if existing = positions.index(position)
            positions.delete_at(existing)
            expressions.delete_at(existing)
          end
          positions << position
          expressions << values[offset]
        end
      end
      new(positions, expressions)
    end
  end

  # The ON CONFLICT clauses of an INSERT, matched to the table's
  # constraints (sqlite3UpsertAnalyzeTarget).
  class UpsertPlan
    getter list_of_clauses : Array(UpsertClause)

    def initialize(@list_of_clauses : Array(UpsertClause))
    end

    # sqlite3UpsertOfIndex for the rowid.
    def clause_for_rowid : UpsertClause?
      @list_of_clauses.find(&.targets_rowid?) || @list_of_clauses.find(&.untargeted?)
    end

    # sqlite3UpsertOfIndex for an index.
    def clause_for(rule : IndexRule) : UpsertClause?
      @list_of_clauses.find(&.index_rule.same?(rule)) || @list_of_clauses.find(&.untargeted?)
    end

    def self.compile(table : WriteTable, upserts : Array(SQL::Upsert), target_name : String) : UpsertPlan?
      return if upserts.empty?
      info = table.table_info
      generated = table.list_of_columns.select(&.generated?).map(&.position).to_set
      clauses = upserts.map_with_index do |upsert, position|
        targets = upsert.target
        if targets.nil? && position < upserts.size - 1
          raise SQLError.new("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint")
        end
        rowid_target = false
        rule = nil.as(IndexRule?)
        if targets
          names = targets.map do |term|
            expression = term.expression
            collation = nil.as(String?)
            while expression.is_a?(SQL::Collate)
              collation ||= expression.collation.value
              expression = expression.operand
            end
            unless expression.is_a?(SQL::ColumnReference)
              raise SQLError.new("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint")
            end
            {expression.column.value, collation}
          end
          if names.size == 1 && (alias_index = info.rowid_alias) && upsert.target_where.nil? &&
             info.list_of_column_names[alias_index].compare(names[0][0], case_insensitive: true) == 0
            rowid_target = true
          elsif table.without_rowid? && upsert.target_where.nil? && names.all? { |name| name[1].nil? } &&
                names.map(&.[0].downcase).sort! == table.definition.list_of_primary_key_columns.map(&.downcase).sort!
            # A WITHOUT ROWID table's PRIMARY KEY is its own key, checked as
            # the rowid is.
            rowid_target = true
          else
            rule = table.list_of_indexes.find { |candidate| UpsertPlan.matches?(candidate, info, names, upsert.target_where) }
            raise SQLError.new("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint") unless rule
          end
        end
        assignments = upsert.assignments.try { |list| AssignmentList.compile(info, list, generated) }
        UpsertClause.new(targets.nil?, rowid_target, rule, assignments, upsert.where, target_name)
      end
      new(clauses)
    end

    def self.matches?(rule : IndexRule, info : TableInfo, names : Array({String, String?}), where : SQL::Expression?) : Bool
      return false unless rule.unique?
      layout = rule.layout
      return false unless layout.key_count == names.size
      return false unless (rule.where.nil? && where.nil?) || (where && rule.where.try(&.to_sql) == where.to_sql)
      names.all? do |name, collation|
        position = info.column_index(name)
        next false unless position
        offset = layout.list_of_key_positions.index(position)
        next false unless offset
        collation.nil? || layout.comparator.list_of_key_columns[offset].collation == Collation.named(collation)
      end
    end
  end

  # One ON CONFLICT clause: its target, and for DO UPDATE the assignments
  # and WHERE, compiled over the existing row and `excluded`.
  class UpsertClause
    getter? untargeted : Bool
    getter? targets_rowid : Bool
    getter index_rule : IndexRule?
    getter assignments : AssignmentList?

    @program : RowProgram? = nil

    def initialize(@untargeted : Bool, @targets_rowid : Bool, @index_rule : IndexRule?, @assignments : AssignmentList?,
                   @where : SQL::Expression?, @target_name : String)
    end

    def do_update? : Bool
      !@assignments.nil?
    end

    def list_of_positions : Array(Int32)
      @assignments.try(&.list_of_positions) || [] of Int32
    end

    def program(run : WriteRun, table : WriteTable) : RowProgram
      @program ||= begin
        assignments = @assignments || raise Error.new("DO NOTHING has no assignments")
        existing = PseudoTable.new(@target_name, table.table_info)
        excluded = PseudoTable.new("excluded", table.table_info)
        excluded.qualified_only = true
        RowProgram.new(run.session, RowProgram.columns(assignments.list_of_expressions), [existing, excluded], @where)
      end
    end
  end
end
