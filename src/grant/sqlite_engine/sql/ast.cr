module Grant::SQLiteEngine::SQL
  # Every node of the syntax tree. Nodes are immutable and compare by value,
  # so a statement printed with `Printer` and parsed again equals the
  # original.
  abstract class Node
    # The node as SQL text, from `Printer`.
    def to_sql : String
      String.build { |io| Printer.new(io).print(self) }
    end
  end

  # Declares a node class: a getter per field, a constructor taking every
  # field in order, and value equality.
  macro define_node(name, parent, *fields)
    class {{name.id}} < {{parent.id}}
      {% for field in fields %}
        getter {{field.var}} : {{field.type}}
      {% end %}

      def initialize({{fields.map { |field| "@#{field.var} : #{field.type}".id }.splat}})
      end

      def_equals_and_hash {{fields.map { |field| "@#{field.var}".id }.splat}}
    end
  end

  # A name as written. `value` is the name SQLite uses, with any quotes
  # removed; `text` is the source text, quotes and all.
  struct Name
    getter value : String
    getter text : String

    def initialize(@value : String, @text : String)
    end

    def self.bare(value : String) : Name
      new(value, value)
    end

    # True when the name equals *other*, ignoring ASCII case, as SQLite
    # compares identifiers.
    def same?(other : String) : Bool
      @value.compare(other, case_insensitive: true) == 0
    end
  end

  enum SortOrder
    None
    Asc
    Desc
  end

  enum NullsOrder
    None
    First
    Last
  end

  enum DistinctMode
    None
    Distinct
    All
  end

  # The conflict-resolution algorithms (lang_conflict.html).
  enum ConflictResolution
    Rollback
    Abort
    Fail
    Ignore
    Replace
  end

  # ---------------------------------------------------------------- expressions

  abstract class Expression < Node
  end

  enum LiteralKind
    Null
    Integer
    Float
    String
    Blob
    CurrentTime
    CurrentDate
    CurrentTimestamp
  end

  # A literal. `text` is the source text (a string keeps its quotes, a
  # number its digit separators).
  define_node Literal, Expression, kind : LiteralKind, text : String

  # A bound parameter: `?`, `?NNN`, `:name`, `@name` or `$name`. `number` is
  # the parameter index SQLite assigns (sqlite3ExprAssignVarNumber).
  define_node Parameter, Expression, text : String, number : Int32

  # `column`, `table.column` or `schema.table.column`.
  define_node ColumnReference, Expression, schema : Name?, table : Name?, column : Name

  enum UnaryOperator
    Negate
    Plus
    Not
    BitNot
  end

  define_node UnaryOperation, Expression, operator : UnaryOperator, operand : Expression

  enum BinaryOperator
    Or
    And
    Equal
    DoubleEqual
    NotEqual
    LessGreater
    Less
    LessOrEqual
    Greater
    GreaterOrEqual
    Is
    IsNot
    IsDistinctFrom
    IsNotDistinctFrom
    BitAnd
    BitOr
    ShiftLeft
    ShiftRight
    Add
    Subtract
    Multiply
    Divide
    Remainder
    Concat
    Extract     # ->
    ExtractText # ->>
  end

  define_node BinaryOperation, Expression, operator : BinaryOperator, left : Expression, right : Expression

  # `LIKE`, `GLOB`, `REGEXP` or `MATCH`, with an optional `NOT` and
  # `ESCAPE`. `operator` is the keyword in upper case.
  define_node LikeOperation, Expression, operator : String, negated : Bool, operand : Expression,
    pattern : Expression, escape : Expression?

  enum NullTestForm
    IsNullKeyword  # x ISNULL
    NotNullKeyword # x NOTNULL
    NotNullWords   # x NOT NULL
  end

  define_node NullTest, Expression, operand : Expression, form : NullTestForm

  define_node Between, Expression, operand : Expression, negated : Bool, low : Expression, high : Expression

  define_node InList, Expression, operand : Expression, negated : Bool, values : Array(Expression)

  define_node InSelect, Expression, operand : Expression, negated : Bool, query : SelectStatement

  # `x IN table` or `x IN table_function(arguments)`; `arguments` is nil
  # when no parentheses follow the name.
  define_node InTable, Expression, operand : Expression, negated : Bool, schema : Name?, table : Name,
    arguments : Array(Expression)?

  define_node Exists, Expression, query : SelectStatement

  define_node ScalarSubquery, Expression, query : SelectStatement

  define_node CaseBranch, Node, condition : Expression, result : Expression

  define_node CaseExpression, Expression, operand : Expression?, branches : Array(CaseBranch),
    else_result : Expression?

  # `CAST(x AS type)`; SQLite allows the type to be empty.
  define_node Cast, Expression, operand : Expression, type_name : TypeName?

  define_node Collate, Expression, operand : Expression, collation : Name

  define_node OrderingTerm, Node, expression : Expression, order : SortOrder, nulls : NullsOrder

  # A function call. `star` is `f(*)`; `order_by` is an aggregate's
  # `ORDER BY` inside the parentheses; `filter` and the window come after.
  define_node FunctionCall, Expression, name : Name, distinct : DistinctMode, arguments : Array(Expression),
    star : Bool, order_by : Array(OrderingTerm), filter : Expression?, over : Window?, over_name : Name?

  # `(a, b, ...)`, two or more values.
  define_node RowValue, Expression, elements : Array(Expression)

  enum RaiseAction
    Ignore
    Rollback
    Abort
    Fail
  end

  define_node Raise, Expression, action : RaiseAction, message : Expression?

  # ------------------------------------------------------------------- windows

  enum FrameUnit
    Range
    Rows
    Groups
  end

  enum FrameBoundKind
    UnboundedPreceding
    Preceding
    CurrentRow
    Following
    UnboundedFollowing
  end

  define_node FrameBound, Node, kind : FrameBoundKind, offset : Expression?

  enum FrameExclude
    None
    NoOthers
    CurrentRow
    Group
    Ties
  end

  # `ROWS|RANGE|GROUPS start` or `... BETWEEN start AND finish`.
  define_node Frame, Node, unit : FrameUnit, start : FrameBound, finish : FrameBound?, exclude : FrameExclude

  define_node Window, Node, base : Name?, partition_by : Array(Expression), order_by : Array(OrderingTerm),
    frame : Frame?

  define_node WindowDefinition, Node, name : Name, window : Window

  # ------------------------------------------------------------------ SELECT

  abstract class Statement < Node
  end

  # `WITH [RECURSIVE] name [(columns)] AS [[NOT] MATERIALIZED] (query), ...`.
  enum Materialization
    Default
    Materialized
    NotMaterialized
  end

  define_node CommonTableExpression, Node, name : Name, columns : Array(Name)?,
    materialization : Materialization, query : SelectStatement

  define_node WithClause, Node, recursive : Bool, tables : Array(CommonTableExpression)

  abstract class ResultColumn < Node
  end

  # `*` or `table.*`.
  define_node AllColumns, ResultColumn, table : Name?

  # An expression with an optional alias.
  define_node ExpressionColumn, ResultColumn, expression : Expression, alias_name : Name?

  class ExpressionColumn
    # The expression's source text, which names the column when it has no
    # alias. Not part of the node's value.
    property span : String? = nil
  end

  abstract class TableSource < Node
  end

  # `[schema.]table [AS alias] [INDEXED BY index | NOT INDEXED]`.
  define_node TableReference, TableSource, schema : Name?, name : Name, alias_name : Name?,
    indexed_by : Name?, not_indexed : Bool

  # `[schema.]function(arguments) [AS alias]`.
  define_node TableFunction, TableSource, schema : Name?, name : Name, arguments : Array(Expression),
    alias_name : Name?

  define_node SubquerySource, TableSource, query : SelectStatement, alias_name : Name?

  # A parenthesized join, `(a JOIN b) AS alias`.
  define_node NestedJoin, TableSource, from : From, alias_name : Name?

  # A join operator: a comma, or `[NATURAL] [LEFT|RIGHT|FULL] [OUTER] |
  # INNER | CROSS] JOIN`. `keywords` holds the words before JOIN, in upper
  # case.
  define_node JoinOperator, Node, comma : Bool, keywords : Array(String)

  define_node FromItem, Node, join : JoinOperator?, source : TableSource, on : Expression?,
    using : Array(Name)?

  define_node From, Node, items : Array(FromItem)

  abstract class SelectCore < Node
  end

  define_node SelectClause, SelectCore, distinct : DistinctMode, columns : Array(ResultColumn), from : From?,
    where : Expression?, group_by : Array(Expression), having : Expression?, windows : Array(WindowDefinition)

  define_node ValuesClause, SelectCore, rows : Array(Array(Expression))

  enum CompoundOperator
    Union
    UnionAll
    Intersect
    Except
  end

  # `LIMIT count [OFFSET offset]`, or `LIMIT offset, count` when
  # `comma_form` is set.
  define_node Limit, Node, count : Expression, offset : Expression?, comma_form : Bool

  # A whole SELECT: the cores joined by compound operators
  # (`operators.size == cores.size - 1`), then ORDER BY and LIMIT.
  define_node SelectStatement, Statement, with_clause : WithClause?, cores : Array(SelectCore),
    operators : Array(CompoundOperator), order_by : Array(OrderingTerm), limit : Limit?

  # ------------------------------------------------------------------- DML

  # The target of INSERT, UPDATE and DELETE: `[schema.]table [AS alias]`.
  define_node QualifiedTable, Node, schema : Name?, name : Name, alias_name : Name?

  # `column = value` or `(a, b) = value`.
  define_node Assignment, Node, columns : Array(Name), parenthesized : Bool, value : Expression

  # `ON CONFLICT [(target) [WHERE ...]] DO NOTHING | DO UPDATE SET ... [WHERE ...]`.
  # `assignments` is nil for DO NOTHING.
  define_node Upsert, Node, target : Array(OrderingTerm)?, target_where : Expression?,
    assignments : Array(Assignment)?, where : Expression?

  enum InsertVerb
    Insert
    Replace
  end

  define_node Insert, Statement, with_clause : WithClause?, verb : InsertVerb, conflict : ConflictResolution?,
    table : QualifiedTable, columns : Array(Name)?, source : SelectStatement?, upserts : Array(Upsert),
    returning : Array(ResultColumn)?

  define_node Update, Statement, with_clause : WithClause?, conflict : ConflictResolution?,
    table : QualifiedTable, indexed_by : Name?, not_indexed : Bool, assignments : Array(Assignment),
    from : From?, where : Expression?, returning : Array(ResultColumn)?

  define_node Delete, Statement, with_clause : WithClause?, table : QualifiedTable, indexed_by : Name?,
    not_indexed : Bool, where : Expression?, returning : Array(ResultColumn)?

  # ------------------------------------------------------------------- DDL

  # A declared type: one or more words, and up to two signed numbers in
  # parentheses (`VARCHAR(255)`, `DECIMAL(10, 2)`).
  define_node TypeName, Node, words : Array(Name), arguments : Array(String)

  # The REFERENCES clause of a foreign key.
  define_node ForeignKeyAction, Node, event : String, action : String

  define_node Deferrability, Node, negated : Bool, initially : String?

  define_node ForeignKeyClause, Node, table : Name, columns : Array(Name)?, actions : Array(ForeignKeyAction),
    match_names : Array(Name), deferrability : Deferrability?

  abstract class ColumnConstraint < Node
  end

  # `CONSTRAINT name`, naming the constraint that follows it.
  define_node ConstraintName, ColumnConstraint, name : Name

  define_node PrimaryKeyColumnConstraint, ColumnConstraint, order : SortOrder,
    conflict : ConflictResolution?, autoincrement : Bool

  define_node NotNullConstraint, ColumnConstraint, conflict : ConflictResolution?

  # The bare `NULL` column constraint, which SQLite accepts and ignores.
  define_node NullConstraint, ColumnConstraint, conflict : ConflictResolution?

  define_node UniqueColumnConstraint, ColumnConstraint, conflict : ConflictResolution?

  define_node CheckColumnConstraint, ColumnConstraint, expression : Expression

  # `DEFAULT value`. `form` records how it was written: a literal, a signed
  # literal, a parenthesized expression, or a bare identifier.
  enum DefaultForm
    Literal
    Parenthesized
    Identifier
  end

  define_node DefaultConstraint, ColumnConstraint, value : Expression, form : DefaultForm

  define_node CollateConstraint, ColumnConstraint, collation : Name

  define_node ReferencesConstraint, ColumnConstraint, clause : ForeignKeyClause

  # A standalone `[NOT] DEFERRABLE [INITIALLY ...]` after a column.
  define_node DeferrableConstraint, ColumnConstraint, deferrability : Deferrability

  # `[GENERATED ALWAYS] AS (expression) [STORED|VIRTUAL]`.
  define_node GeneratedConstraint, ColumnConstraint, expression : Expression, storage : Name?, generated_always : Bool

  define_node ColumnDefinition, Node, name : Name, type_name : TypeName?, constraints : Array(ColumnConstraint)

  abstract class TableConstraint < Node
  end

  define_node TableConstraintName, TableConstraint, name : Name

  define_node PrimaryKeyTableConstraint, TableConstraint, columns : Array(OrderingTerm), autoincrement : Bool,
    conflict : ConflictResolution?

  define_node UniqueTableConstraint, TableConstraint, columns : Array(OrderingTerm), conflict : ConflictResolution?

  define_node CheckTableConstraint, TableConstraint, expression : Expression, conflict : ConflictResolution?

  define_node ForeignKeyTableConstraint, TableConstraint, columns : Array(Name), clause : ForeignKeyClause

  # Table options after the closing parenthesis.
  define_node TableOption, Node, without_rowid : Bool, text : Name

  define_node CreateTable, Statement, temporary : Name?, if_not_exists : Bool, schema : Name?, name : Name,
    columns : Array(ColumnDefinition), constraints : Array(TableConstraint), options : Array(TableOption),
    as_select : SelectStatement?

  define_node CreateIndex, Statement, unique : Bool, if_not_exists : Bool, schema : Name?, name : Name,
    table : Name, columns : Array(OrderingTerm), where : Expression?

  define_node CreateView, Statement, temporary : Name?, if_not_exists : Bool, schema : Name?, name : Name,
    columns : Array(Name)?, query : SelectStatement

  enum TriggerTime
    None
    Before
    After
    InsteadOf
  end

  enum TriggerEvent
    Delete
    Insert
    Update
  end

  define_node CreateTrigger, Statement, temporary : Name?, if_not_exists : Bool, schema : Name?, name : Name,
    time : TriggerTime, event : TriggerEvent, update_columns : Array(Name)?, table_schema : Name?, table : Name,
    for_each_row : Bool, when_condition : Expression?, body : Array(Statement)

  # `CREATE VIRTUAL TABLE ... USING module(arguments)`; each argument is
  # kept as its source text.
  define_node CreateVirtualTable, Statement, if_not_exists : Bool, schema : Name?, name : Name, module_name : Name,
    arguments : Array(String)?

  enum DropKind
    Table
    Index
    View
    Trigger
  end

  define_node Drop, Statement, kind : DropKind, if_exists : Bool, schema : Name?, name : Name

  abstract class AlterAction < Node
  end

  define_node RenameTable, AlterAction, new_name : Name

  define_node RenameColumn, AlterAction, column_keyword : Bool, old_name : Name, new_name : Name

  define_node AddColumn, AlterAction, column_keyword : Bool, column : ColumnDefinition

  define_node DropColumn, AlterAction, column_keyword : Bool, column_name : Name

  define_node AlterTable, Statement, schema : Name?, table : Name, action : AlterAction

  # ------------------------------------------------------ transactions and the rest

  enum TransactionMode
    None
    Deferred
    Immediate
    Exclusive
  end

  # `transaction_name` is the optional name after `TRANSACTION`, which
  # SQLite ignores; `transaction_keyword` records whether TRANSACTION was written.
  define_node Begin, Statement, mode : TransactionMode, transaction_keyword : Bool, transaction_name : Name?

  # COMMIT or its synonym END.
  define_node Commit, Statement, keyword : String, transaction_keyword : Bool, transaction_name : Name?

  # ROLLBACK, or `ROLLBACK TO [SAVEPOINT] name` when `savepoint` is set.
  define_node Rollback, Statement, transaction_keyword : Bool, transaction_name : Name?, savepoint : Name?,
    savepoint_keyword : Bool

  define_node Savepoint, Statement, name : Name

  define_node Release, Statement, savepoint_keyword : Bool, name : Name

  enum PragmaForm
    Bare
    Assignment
    Call
  end

  # `PRAGMA [schema.]name [= value | (value)]`; `value` keeps the source
  # text of the number or name.
  define_node Pragma, Statement, schema : Name?, name : Name, form : PragmaForm, value : String?

  define_node Attach, Statement, database_keyword : Bool, file : Expression, schema : Expression, key : Expression?

  define_node Detach, Statement, database_keyword : Bool, schema : Expression

  define_node Analyze, Statement, schema : Name?, name : Name?

  define_node Reindex, Statement, schema : Name?, name : Name?

  define_node Vacuum, Statement, schema : Name?, into : Expression?

  define_node Explain, Statement, query_plan : Bool, statement : Statement
end
