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
    getter merged_columns = Set(Int32).new
    property? right_of_left_join = false
    # Index hint: the INDEXED BY name, or NOT INDEXED.
    property indexed_by : String? = nil
    property? not_indexed = false

    def initialize(@match_name : String, @slot : Int32, @list_of_columns : Array(SourceColumn), @table : TableInfo?)
    end

    def has_rowid? : Bool
      table = @table
      !table.nil? && !table.without_rowid?
    end

    def column_index(name : String) : Int32?
      @list_of_columns.index { |column| column.name.compare(name, case_insensitive: true) == 0 }
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
    # Set when an expression of this query (or a query inside it) refers to
    # a row of an enclosing query.
    property? correlated = false
    # Slots of enclosing queries this query refers to.
    getter outer_slots = Set(Int32).new

    def initialize(@parent : QueryContext?, @first_slot : Int32, @ctes : CteScope?)
    end

    def owns_slot?(slot : Int32) : Bool
      slot >= @first_slot
    end
  end

  # The aggregate calls of one SELECT core.
  class AggregateCollector
    getter list_of_calls = [] of AggregateCall
    # True while compiling an aggregate's arguments, where another
    # aggregate is misuse.
    property? inside_call = false
  end
end
