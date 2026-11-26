module Grant::SQLiteEngine::Query
  # A column a FROM entry offers to name resolution.
  # A column a FROM entry exposes. *realify*: an integer read from it
  # becomes a real when its affinity is REAL (OP_RealAffinity).
  record SourceColumn, name : String, affinity : ExpressionAffinity, collation : Collation, realify : Bool = true

  # One FROM entry: what it is called, the slot its rows go in, its
  # columns, and whether it has a rowid (tables do; subqueries, views and
  # CTEs do not).
  class FromEntry
    getter match_name : String
    getter slot : Int32
    getter list_of_columns : Array(SourceColumn)
    getter table : TableInfo?
    # Columns of this entry merged into an earlier entry by USING or
    # NATURAL: skipped by unqualified names and by `*`.
    # Nil until a column is merged.
    @merged_columns : Set(Int32)? = nil
    property? right_of_left_join = false
    # Index hint: the INDEXED BY name, or NOT INDEXED.
    property indexed_by : String? = nil
    property? not_indexed = false
    # The columns the compiled query reads from this entry's rows.
    getter column_use = ColumnUse.new
    # How many leading columns `*` and NATURAL joins see; the rest are
    # HIDDEN columns of a table-valued function (json_each's json and
    # root), found only by name.
    getter visible_column_count : Int32
    # For a table-valued function, the column holding the rowid its cursor
    # reports (xRowid); never found by its own name.
    getter rowid_column : Int32?
    # The database whose schema a `schema.table.column` name must match:
    # a table's own, main for a view or table-valued function, nil for a
    # subquery or CTE (no schema matches it).
    getter database : Database?

    def initialize(@match_name : String, @slot : Int32, @list_of_columns : Array(SourceColumn), @table : TableInfo?,
                   visible_column_count : Int32? = nil, @rowid_column : Int32? = nil, database : Database? = nil)
      @visible_column_count = visible_column_count || @list_of_columns.size
      @database = database || @table.try(&.database)
    end

    def merged_columns : Set(Int32)
      @merged_columns ||= Set(Int32).new
    end

    def merged_column?(index : Int32) : Bool
      merged = @merged_columns
      !merged.nil? && merged.includes?(index)
    end

    def has_rowid? : Bool
      return true if @rowid_column
      table = @table
      !table.nil? && !table.without_rowid?
    end

    def column_index(name : String) : Int32?
      rowid_column = @rowid_column
      @list_of_columns.each_with_index do |column, index|
        next if index == rowid_column
        return index if column.name.compare(name, case_insensitive: true) == 0
      end
      nil
    end
  end

  # A WITH table visible to a query.
  class CteDefinition
    getter name : String
    getter list_of_column_names : Array(String)?
    getter query : SQL::SelectStatement
    getter? recursive : Bool
    # The CTE scope it was defined in, which its own body sees.
    getter enclosing : CteScope?

    def initialize(@name : String, @list_of_column_names : Array(String)?, @query : SQL::SelectStatement, @recursive : Bool,
                   @enclosing : CteScope?)
    end
  end

  # The WITH tables of one query level, and the levels around it.
  class CteScope
    getter parent : CteScope?
    getter list_of_definitions = [] of CteDefinition

    def initialize(@parent : CteScope?)
    end

    def find(name : String) : CteDefinition?
      scope = self
      while scope
        if found = scope.list_of_definitions.find { |definition| definition.name.compare(name, case_insensitive: true) == 0 }
          return found
        end
        scope = scope.parent
      end
      nil
    end
  end

  # Name resolution state for one SELECT core: its FROM entries, its
  # result aliases, the enclosing query (for correlated references), and
  # what has been learned while compiling it.
  class QueryContext
    getter parent : QueryContext?
    getter list_of_entries = [] of FromEntry
    getter first_slot : Int32
    property ctes : CteScope?
    # Result column aliases and their expressions, usable by WHERE, GROUP
    # BY, HAVING and ORDER BY when no FROM column has the name.
    property list_of_aliases = [] of {String, SQL::Expression}
    property? aliases_visible = false
    # Collects aggregate calls while compiling the result columns, HAVING
    # and ORDER BY of an aggregate query.
    property aggregates : AggregateCollector? = nil
    # True for a query with GROUP BY or an aggregate in its result set.
    property? aggregate_query = false
    # NC_AllowAgg: an aggregate call here resolves (whether it can be
    # computed is decided by where it belongs, `aggregates`).
    property? aggregates_allowed = false
    # NC_InAggFunc: while an aggregate's arguments are resolved, another
    # aggregate of this query is misuse.
    property? inside_aggregate_call = false
    # Set when an expression of this query (or a query inside it) refers to
    # a row of an enclosing query.
    property? correlated = false
    # Slots of enclosing queries this query refers to; nil until it
    # refers to one.
    @outer_slots : Set(Int32)? = nil

    # The outer slots of a query that refers to none, shared by every such
    # query: nothing adds to it (`add_outer_slot` adds to the query's own).
    NO_OUTER_SLOTS = Set(Int32).new

    def outer_slots : Set(Int32)
      @outer_slots || NO_OUTER_SLOTS
    end

    def add_outer_slot(slot : Int32) : Nil
      (@outer_slots ||= Set(Int32).new) << slot
    end

    def initialize(@parent : QueryContext?, @first_slot : Int32, @ctes : CteScope?)
    end

    def owns_slot?(slot : Int32) : Bool
      slot >= @first_slot
    end
  end

  # The aggregate calls of one SELECT core.
  class AggregateCollector
    getter list_of_calls = [] of AggregateCall
  end
end
