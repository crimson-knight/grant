require "../columns"
require "../async"
require "./where_chain"

# Lazy, chainable SQL query builder returned by `Model.where`, `Model.order`, etc.
#
# A `Builder` accumulates query components (WHERE/ORDER/GROUP BY/LIMIT/…) and
# does **not** touch the database until a terminal method is called. Most
# chaining methods mutate and return `self`, so calls compose left-to-right:
#
# ```
# class User < Grant::Base
#   column id : Int64, primary: true
#   column email : String
#   column active : Bool
# end
#
# # Lazy: nothing runs here…
# query = User.where(active: true).order(id: :desc).limit(10)
#
# # …a terminal method executes the SQL:
# query.select     # => Array(User)
# query.first      # => User? (LIMIT 1)
# query.count      # => Int64
# query.delete_all # => Int64 (rows affected)
# ```
#
# Because `Builder` includes `Enumerable(Model)`, collection methods (`map`,
# `select`, `reduce`, `each`, …) work directly on a chain without first calling
# `.select`/`.all`.
#
# Boolean logic can be grouped with the block forms `or { |q| ... }` and
# `not { |q| ... }`, or chained inline with `and`/`or`. Advanced operators
# (`like`, `gt`, `not_in`, …) are available via the no-argument `where`, which
# returns a `WhereChain`.
class Grant::Query::Builder(Model)
  include Grant::Async::QueryMethods(Model)
  include Enumerable(Model)

  enum DbType
    Mysql
    Sqlite
    Pg
  end

  enum Sort
    Ascending
    Descending
  end

  alias WhereField = NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type) |
                     NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type) |
                     NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
  alias AssociationQuery = Symbol | Hash(Symbol, Array(Symbol))

  getter db_type : DbType
  getter where_fields : Array(WhereField) = [] of WhereField
  getter order_fields = [] of NamedTuple(field: String, direction: Sort)
  getter group_fields = [] of NamedTuple(field: String)
  getter offset : Int64?
  getter limit : Int64?
  getter eager_load_associations : Array(AssociationQuery) = [] of AssociationQuery
  getter preload_associations : Array(AssociationQuery) = [] of AssociationQuery
  getter includes_associations : Array(AssociationQuery) = [] of AssociationQuery
  getter lock_mode : Grant::Locking::LockMode?
  property select_columns : Array(String)?

  # Join clauses for INNER JOIN and LEFT JOIN operations.
  getter join_clauses = [] of NamedTuple(type: Symbol, table: String, on: String)

  # Flag for SELECT DISTINCT queries.
  getter? distinct : Bool = false

  # Having clauses for aggregate filtering after GROUP BY.
  getter having_clauses = [] of NamedTuple(stmt: String, value: Grant::Columns::Type)

  # Flag for null relation (none) — short-circuits to empty results.
  getter? is_none : Bool = false

  def initialize(@db_type, @boolean_operator = :and)
  end

  def assembler : Assembler::Base(Model)
    case @db_type
    when DbType::Pg
      Assembler::Pg(Model).new self
    when DbType::Mysql
      Assembler::Mysql(Model).new self
    when DbType::Sqlite
      Assembler::Sqlite(Model).new self
    else
      raise "Unknown database type: #{@db_type}"
    end
  end

  # Adds equality (or set/range) conditions from keyword arguments, ANDed together.
  #
  # Each *matches* pair becomes a condition on that column. The operator is
  # inferred from the value type:
  # - scalar → `column = value`
  # - `Array` → `column IN (...)` (nils dropped)
  # - `Range` → `column BETWEEN begin AND end`
  # - `Enum` → compared by its `to_s`
  # - another `Builder` → `column IN (subquery)`
  #
  # Returns `self` for chaining.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  #   column active : Bool
  # end
  #
  # User.where(active: true)
  # User.where(active: true, email: "a@example.com") # ANDed
  # User.where(id: [1, 2, 3])                        # id IN (1, 2, 3)
  # User.where(id: 1..10)                            # id BETWEEN 1 AND 10
  # ```
  def where(**matches) : self
    where(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `where(**matches)` — accepts a pre-built collection
  # of column/value pairs.
  #
  # ```
  # User.where({active: true, email: "a@example.com"})
  # ```
  def where(matches) : self
    matches.each do |field, value|
      if value.is_a?(Array)
        and(field: field.to_s, operator: :in, value: value.compact)
      elsif value.is_a?(Enum)
        and(field: field.to_s, operator: :eq, value: value.to_s)
      elsif value.is_a?(Range)
        # Handle range as BETWEEN operation
        and(field: field.to_s, operator: :gteq, value: value.begin)
        and(field: field.to_s, operator: :lteq, value: value.end)
      elsif value.is_a?(Builder)
        # Handle subquery
        and_subquery(field: field.to_s, subquery: value)
      else
        and(field: field.to_s, operator: :eq, value: value)
      end
    end

    self
  end

  # Adds a single condition with an explicit *operator*, ANDed onto the query.
  #
  # - *field*: column name (Symbol or String).
  # - *operator*: comparison operator symbol, e.g. `:eq`, `:neq`, `:gt`, `:lt`,
  #   `:gteq`, `:lteq`, `:in`, `:nin`, `:like`, `:nlike`.
  # - *value*: the value to compare against.
  #
  # Returns `self` for chaining.
  #
  # ```
  # User.where(:id, :gt, 100)
  # User.where(:email, :like, "%@example.com")
  # ```
  def where(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type) : self
    and(field: field.to_s, operator: operator, value: value)
  end

  # Adds a raw SQL condition *stmt*, ANDed onto the query.
  #
  # Use a `?` placeholder and pass *value* to bind it safely.
  #
  # ```
  # User.where("LENGTH(email) > ?", 20)
  # User.where("active = true") # no bind value
  # ```
  def where(stmt : String, value : Grant::Columns::Type = nil) : self
    and(stmt: stmt, value: value)
  end

  # Returns a WhereChain for advanced where methods.
  #
  # Example:
  # ```
  # User.where.like(:email, "%@gmail.com")
  #   .where.gt(:age, 18)
  #   .where.not_in(:status, ["banned", "suspended"])
  # ```
  def where : WhereChain(Model)
    WhereChain(Model).new(self)
  end

  # Adds an AND condition with an explicit *operator*. Synonym of `where(field, operator, value)`.
  #
  # See `where(field, operator, value)` for the operator list. Returns `self`.
  #
  # ```
  # User.where(active: true).and(:id, :gt, 100)
  # ```
  def and(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type) : self
    @where_fields << {join: :and, field: field.to_s, operator: operator, value: value}

    self
  end

  # Adds a raw SQL AND condition *stmt*, optionally binding *value* to a `?`. Returns `self`.
  #
  # ```
  # User.where(active: true).and("LENGTH(email) > ?", 10)
  # ```
  def and(stmt : String, value : Grant::Columns::Type = nil) : self
    @where_fields << {join: :and, stmt: stmt, value: value}

    self
  end

  # Adds AND equality/set/range conditions from keyword arguments. Synonym of `where(**matches)`. Returns `self`.
  #
  # ```
  # User.where(active: true).and(email: "a@example.com")
  # ```
  def and(**matches) : self
    and(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `and(**matches)`.
  def and(matches) : self
    matches.each do |field, value|
      if value.is_a?(Array)
        and(field: field.to_s, operator: :in, value: value.compact)
      elsif value.is_a?(Enum)
        and(field: field.to_s, operator: :eq, value: value.to_s)
      elsif value.is_a?(Range)
        # Handle range as BETWEEN operation
        and(field: field.to_s, operator: :gteq, value: value.begin)
        and(field: field.to_s, operator: :lteq, value: value.end)
      else
        and(field: field.to_s, operator: :eq, value: value)
      end
    end
    self
  end

  # Adds OR equality/set/range conditions from keyword arguments.
  #
  # Each pair is joined to the existing conditions with OR (same value-type
  # inference as `where`). Returns `self`.
  #
  # ```
  # User.where(active: true).or(email: "admin@example.com")
  # # => WHERE active = true OR email = 'admin@example.com'
  # ```
  #
  # For a parenthesized OR group, use the block form `or { |q| ... }`.
  def or(**matches) : self
    or(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `or(**matches)`.
  def or(matches) : self
    matches.each do |field, value|
      if value.is_a?(Array)
        or(field: field.to_s, operator: :in, value: value.compact)
      elsif value.is_a?(Enum)
        or(field: field.to_s, operator: :eq, value: value.to_s)
      elsif value.is_a?(Range)
        # Handle range as BETWEEN operation - for OR, we need to group these
        or(field: field.to_s, operator: :gteq, value: value.begin)
        or(field: field.to_s, operator: :lteq, value: value.end)
      else
        or(field: field.to_s, operator: :eq, value: value)
      end
    end
    self
  end

  # Adds an OR condition with an explicit *operator*. See `where(field, operator, value)`. Returns `self`.
  #
  # ```
  # User.where(active: true).or(:id, :lt, 10)
  # # => WHERE active = true OR id < 10
  # ```
  def or(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type) : self
    @where_fields << {join: :or, field: field.to_s, operator: operator, value: value}

    self
  end

  # Adds a raw SQL OR condition *stmt*, optionally binding *value* to a `?`. Returns `self`.
  #
  # ```
  # User.where(active: true).or("LENGTH(email) > ?", 30)
  # ```
  def or(stmt : String, value : Grant::Columns::Type = nil) : self
    @where_fields << {join: :or, stmt: stmt, value: value}

    self
  end

  # Appends an ascending ORDER BY on a single *field*. Returns `self`.
  #
  # ```
  # User.order(:email) # => ORDER BY email ASC
  # ```
  def order(field : Symbol) : self
    @order_fields << {field: field.to_s, direction: Sort::Ascending}

    self
  end

  # Appends ascending ORDER BY clauses for several *fields* in order. Returns `self`.
  #
  # ```
  # User.order([:active, :email]) # => ORDER BY active ASC, email ASC
  # ```
  def order(fields : Array(Symbol)) : self
    fields.each do |field|
      order field
    end

    self
  end

  # Appends ORDER BY clauses with explicit directions from keyword arguments. Returns `self`.
  #
  # Direction values may be `:asc`/`:desc` (or the strings). Clauses are appended
  # in the order given, so later `order` calls add lower-priority sorts.
  #
  # ```
  # User.where(active: true).order(id: :desc)
  # User.order(active: :asc, email: :desc) # => ORDER BY active ASC, email DESC
  # ```
  def order(**dsl) : self
    order(dsl)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `order(**dsl)`.
  def order(dsl) : self
    dsl.each do |field, dsl_direction|
      direction = Sort::Ascending

      if dsl_direction == "desc" || dsl_direction == :desc
        direction = Sort::Descending
      end

      @order_fields << {field: field.to_s, direction: direction}
    end

    self
  end

  # Appends a GROUP BY on a single *field*. Returns `self`.
  #
  # Typically paired with an aggregate `select` and/or `having`.
  #
  # ```
  # User.group_by(:active) # => GROUP BY active
  # ```
  def group_by(field : Symbol) : self
    @group_fields << {field: field.to_s}

    self
  end

  # Appends GROUP BY clauses for several *fields*. Returns `self`.
  #
  # ```
  # User.group_by([:active, :email]) # => GROUP BY active, email
  # ```
  def group_by(fields : Array(Symbol)) : self
    fields.each do |field|
      group_by field
    end

    self
  end

  # Appends GROUP BY clauses from keyword-argument keys (values are ignored). Returns `self`.
  #
  # ```
  # User.group_by(active: true) # => GROUP BY active
  # ```
  def group_by(**dsl) : self
    group_by(dsl)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `group_by(**dsl)`.
  def group_by(dsl) : self
    dsl.each do |field, _|
      @group_fields << {field: field.to_s}
    end

    self
  end

  # Acquires a row-level database lock on the selected rows. Returns `self`.
  #
  # *mode* defaults to `LockMode::Update` (`FOR UPDATE`). Must run inside a
  # transaction to be meaningful. SQLite has no row-level locking, so the lock
  # is a no-op there.
  #
  # ```
  # User.transaction do
  #   user = User.where(id: 1).lock.first!
  #   # row is FOR UPDATE-locked until the transaction commits
  # end
  # ```
  def lock(mode : Grant::Locking::LockMode = Grant::Locking::LockMode::Update) : self
    @lock_mode = mode
    self
  end

  # Adds an INNER JOIN clause to the query.
  #
  # Can accept explicit table/ON pairs for custom join conditions.
  #
  # ```
  # User.joins("posts", on: "posts.user_id = users.id")
  #   .where(active: true)
  # # => SELECT ... FROM users INNER JOIN posts ON posts.user_id = users.id WHERE active = true
  # ```
  def joins(table : String, *, on : String) : self
    @join_clauses << {type: :inner, table: table, on: on}
    self
  end

  # Adds an INNER JOIN clause resolved from an association *name*.
  #
  # The target table and join condition are derived automatically from the
  # association metadata registered by the `belongs_to`/`has_many`/`has_one`
  # macros (via `Grant::AssociationRegistry`). No explicit `on:` SQL is needed.
  #
  # ```
  # # Parent has_many :students  (students.parent_id -> parents.id)
  # Parent.joins(:students).where(name: "test")
  # # => SELECT ... FROM parents INNER JOIN students ON students.parent_id = parents.id ...
  #
  # # Klass belongs_to :teacher  (klasses.teacher_id -> teachers.id)
  # Klass.joins(:teacher)
  # # => SELECT ... FROM klasses INNER JOIN teachers ON teachers.id = klasses.teacher_id
  # ```
  def joins(association : Symbol) : self
    @join_clauses << resolve_association_join(association, :inner)
    self
  end

  # Adds INNER JOINs for multiple association names at once.
  def joins(*associations : Symbol) : self
    associations.each { |assoc| joins(assoc) }
    self
  end

  # Adds a LEFT OUTER JOIN clause to the query.
  #
  # Left joins include all rows from the left table, even when there
  # is no matching row in the joined table (NULL values are used).
  #
  # ```
  # User.left_joins("posts", on: "posts.user_id = users.id")
  #   .where("posts.id IS NULL")
  # # => SELECT ... FROM users LEFT JOIN posts ON posts.user_id = users.id WHERE posts.id IS NULL
  # ```
  def left_joins(table : String, *, on : String) : self
    @join_clauses << {type: :left, table: table, on: on}
    self
  end

  # Adds a LEFT OUTER JOIN clause resolved from an association *name*.
  #
  # Like `joins(Symbol)` but emits a LEFT JOIN. See `joins(Symbol)` for how the
  # table and ON condition are derived from association metadata.
  #
  # ```
  # Parent.left_joins(:students)
  # # => SELECT ... FROM parents LEFT JOIN students ON students.parent_id = parents.id
  # ```
  def left_joins(association : Symbol) : self
    @join_clauses << resolve_association_join(association, :left)
    self
  end

  # Adds LEFT JOINs for multiple association names at once.
  def left_joins(*associations : Symbol) : self
    associations.each { |assoc| left_joins(assoc) }
    self
  end

  # Resolves an association *name* into a join clause `{type:, table:, on:}`.
  #
  # Uses `Grant::AssociationRegistry` metadata (populated by the association
  # macros). The ON condition depends on where the foreign key lives:
  #
  # - `belongs_to`: FK is on *this* model's table, pointing at the target's PK,
  #   so `target.primary_key = current.foreign_key`.
  # - `has_many` / `has_one`: FK is on the *target* table, pointing back at this
  #   model's PK, so `target.foreign_key = current.primary_key`.
  #
  # Raises `ArgumentError` if the association is unknown.
  private def resolve_association_join(association : Symbol, type : Symbol)
    meta = Grant::AssociationRegistry.get(Model.name, association.to_s)
    raise ArgumentError.new("Unknown association #{association.inspect} for #{Model.name}") unless meta

    target_table = meta[:target_class].table_name
    current_table = Model.table_name
    foreign_key = meta[:foreign_key]
    primary_key = meta[:primary_key]

    on = case meta[:type]
         when :belongs_to
           # FK lives on the current model's table.
           "#{target_table}.#{primary_key} = #{current_table}.#{foreign_key}"
         else
           # has_many / has_one: FK lives on the target table.
           "#{target_table}.#{foreign_key} = #{current_table}.#{primary_key}"
         end

    {type: type, table: target_table, on: on}
  end

  # Sets the query to return only distinct (unique) rows.
  #
  # When enabled, duplicate rows are removed from the result set.
  #
  # ```
  # User.where(active: true).distinct
  # # => SELECT DISTINCT ... FROM users WHERE active = true
  # ```
  def distinct : self
    @distinct = true
    self
  end

  # Adds a HAVING clause for filtering aggregate results.
  #
  # HAVING is used with GROUP BY to filter groups based on aggregate
  # conditions. It operates on grouped results, unlike WHERE which
  # filters individual rows.
  #
  # ```
  # User.group_by(:department)
  #   .having("COUNT(*) > ?", 5)
  # # => SELECT ... FROM users GROUP BY department HAVING COUNT(*) > 5
  # ```
  def having(stmt : String, value : Grant::Columns::Type = nil) : self
    @having_clauses << {stmt: stmt, value: value}
    self
  end

  # Marks this query as a null relation, returning empty results.
  #
  # A null relation is useful when you need to guarantee an empty
  # result set while maintaining a chainable query interface. The
  # query will append `WHERE 1=0` to short-circuit execution.
  #
  # ```
  # User.none.select           # => []
  # User.none.count            # => 0
  # User.none.any?             # => false
  # User.none.where(name: "x") # => [] (still returns nothing)
  # ```
  def none : self
    @is_none = true
    self
  end

  # Clears existing order and replaces with new ordering.
  #
  # Useful when a default scope sets an order that you want to override
  # completely rather than append to.
  #
  # ```
  # User.order(name: :asc).reorder(created_at: :desc)
  # # => SELECT ... FROM users ORDER BY created_at DESC
  # ```
  def reorder(**dsl) : self
    @order_fields.clear
    order(**dsl)
  end

  # Clears existing order and replaces with a single field ascending.
  #
  # ```
  # User.order(name: :desc).reorder(:created_at)
  # # => SELECT ... FROM users ORDER BY created_at ASC
  # ```
  def reorder(field : Symbol) : self
    @order_fields.clear
    order(field)
  end

  # Reverses the direction of all existing order clauses.
  #
  # Ascending becomes Descending and vice versa. If no order is set,
  # this is a no-op.
  #
  # ```
  # User.order(name: :asc, created_at: :desc).reverse_order
  # # => SELECT ... FROM users ORDER BY name DESC, created_at ASC
  # ```
  def reverse_order : self
    @order_fields = @order_fields.map do |field|
      new_direction = field[:direction] == Sort::Ascending ? Sort::Descending : Sort::Ascending
      {field: field[:field], direction: new_direction}
    end
    self
  end

  # Clears existing WHERE conditions and replaces with new ones.
  #
  # Useful when you inherit a scope with conditions you want to
  # completely replace rather than append to.
  #
  # ```
  # User.where(active: true).rewhere(active: false)
  # # => SELECT ... FROM users WHERE active = false
  # ```
  def rewhere(**matches) : self
    @where_fields.clear
    where(**matches)
  end

  # Clears existing column projection and replaces with new columns.
  #
  # Hydration reads by column name, so unselected columns remain nil.
  #
  # ```
  # User.where(active: true).select(:id, :name).reselect(:id, :email).select
  # # => SELECT id, email FROM users WHERE active = ?
  # ```
  def reselect(*columns : Symbol) : self
    @select_columns = columns.map(&.to_s).to_a
    self
  end

  # Clears existing GROUP BY and replaces with a new grouping.
  #
  # ```
  # User.group_by(:status).regroup(:department)
  # # => SELECT ... FROM users GROUP BY department
  # ```
  def regroup(field : Symbol) : self
    @group_fields.clear
    group_by(field)
  end

  # Clears existing GROUP BY and replaces with new groupings.
  #
  # ```
  # User.group_by(:status).regroup(:department, :role)
  # # => SELECT ... FROM users GROUP BY department, role
  # ```
  def regroup(*fields : Symbol) : self
    @group_fields.clear
    fields.each { |f| group_by(f) }
    self
  end

  # Returns a relation with the named clause components stripped.
  #
  # Mirrors ActiveRecord's `unscope`. Useful for removing parts of an inherited
  # scope while keeping the rest of the chain intact. Recognized components:
  # `:where`, `:order`, `:limit`, `:offset`, `:group` (alias `:group_by`),
  # `:having`, `:joins`, `:select`, `:distinct`, `:lock`.
  #
  # ```
  # User.where(active: true).order(name: :asc).unscope(:order)
  # # => SELECT ... FROM users WHERE active = ?   (no ORDER BY)
  #
  # User.where(active: true).limit(10).offset(5).unscope(:limit, :offset)
  # # => SELECT ... FROM users WHERE active = ?   (no LIMIT/OFFSET)
  # ```
  #
  # Raises `ArgumentError` for an unrecognized component.
  def unscope(*components : Symbol) : self
    components.each do |component|
      case component
      when :where
        @where_fields.clear
      when :order
        @order_fields.clear
      when :limit
        @limit = nil
      when :offset
        @offset = nil
      when :group, :group_by
        @group_fields.clear
      when :having
        @having_clauses.clear
      when :joins
        @join_clauses.clear
      when :select
        @select_columns = nil
      when :distinct
        @distinct = false
      when :lock
        @lock_mode = nil
      else
        raise ArgumentError.new("unscope: unknown component #{component.inspect}")
      end
    end
    self
  end

  # Sets the OFFSET — the number of leading rows to skip. Returns `self`.
  #
  # *num* is coerced to `Int64`; pass `nil` to clear a previously set offset.
  # Usually combined with `limit` and `order` for pagination.
  #
  # ```
  # User.order(id: :asc).limit(10).offset(20) # rows 21..30
  # ```
  def offset(num) : self
    @offset = num.nil? ? nil : num.to_i64

    self
  end

  # Sets the LIMIT — the maximum number of rows to return. Returns `self`.
  #
  # *num* is coerced to `Int64`; pass `nil` to clear a previously set limit.
  #
  # ```
  # User.where(active: true).order(id: :desc).limit(10)
  # ```
  def limit(num) : self
    @limit = num.nil? ? nil : num.to_i64

    self
  end

  # Executes the query and returns the matching records as an `Array(Model)`.
  #
  # This is the terminal method that actually runs the SQL the chain has built
  # up. Applies any `includes`/`preload`/`eager_load` association loading. A
  # `none` relation short-circuits to `[]` without touching the database.
  #
  # Routes through IN-list chunking (when a `where(col: array)` exceeds the
  # chunk limit) and an index-hint safe fallback. The single-query path is
  # `select_single`.
  #
  # NOTE: the column-projecting `select(*columns : Symbol)` overload is a
  # *chainable* setter that returns `self`; this no-argument form is the
  # *terminal* executor that returns the rows.
  #
  # ```
  # users = User.where(active: true).order(id: :desc).limit(10).select
  # # => [#<User ...>, ...]
  # ```
  def select : Array(Model)
    # Short-circuit for null relation
    return [] of Model if is_none?

    if should_chunk_in?
      return chunked_select
    end

    with_index_hint_fallback do |q|
      q.select_single
    end
  end

  # Executes a single SELECT (no IN-chunking), applying eager loading. Used by
  # the chunked/fallback paths and directly when no chunking is needed.
  protected def select_single : Array(Model)
    records = assembler.select.run

    # Apply eager loading if any associations are specified
    all_associations = @includes_associations + @preload_associations + @eager_load_associations
    unless all_associations.empty?
      Grant::AssociationLoader.load_associations(records, all_associations)
    end

    records
  end

  # Executes the query and returns all matching records. Alias for `select`.
  #
  # ```
  # User.where(active: true).all # => [#<User ...>, ...]
  # ```
  def all : Array(Model)
    self.select
  end

  # Returns the SQL string this query would execute, without running it.
  #
  # Handy for debugging or logging the generated query.
  #
  # ```
  # User.where(active: true).order(id: :desc).raw_sql
  # # => "SELECT ... FROM users WHERE active = ? ORDER BY id DESC"
  # ```
  def raw_sql : String
    assembler.select.raw_sql
  end

  # Runs the query through the adapter's `EXPLAIN` and returns the plan text.
  #
  # Adapter-aware: PostgreSQL/MySQL use `EXPLAIN` (and `EXPLAIN ANALYZE` when
  # *analyze* is true), SQLite uses `EXPLAIN QUERY PLAN`. Degrades gracefully —
  # if the adapter rejects the statement (e.g. ANALYZE on an old MySQL), the
  # error message is returned as the plan text instead of raising.
  #
  # ```
  # puts User.where(active: true).explain
  # puts User.where(active: true).explain(analyze: true) # PG/MySQL real plan
  # ```
  def explain(analyze : Bool = false) : String
    assembler.explain(analyze)
  end

  # Executes the query with `LIMIT 1` and returns the first record, or `nil`.
  #
  # Add an `order` for a deterministic result.
  #
  # ```
  # User.where(active: true).order(id: :asc).first # => #<User ...> or nil
  # ```
  def first : Model?
    limit(1).select.first?
  end

  # Like `first` but raises `Grant::Querying::NotFound` when nothing matches.
  #
  # ```
  # User.where(active: true).first! # => #<User ...> or raises
  # ```
  def first! : Model
    first || raise Grant::Querying::NotFound.new("No record found")
  end

  # Executes the query with `LIMIT n` and returns up to *n* records as an Array.
  #
  # ```
  # User.where(active: true).order(id: :desc).first(3) # => up to 3 users
  # ```
  def first(n : Int32) : Array(Model)
    limit(n).select
  end

  # Returns `true` if the query matches at least one record, otherwise `false`.
  #
  # A `none` relation is always `false`. Equivalent to `exists?`.
  #
  # ```
  # User.where(active: true).any? # => true/false
  # ```
  def any? : Bool
    return false if is_none?
    !first.nil?
  end

  # Returns the one record matching the query, asserting uniqueness.
  #
  # Raises `Grant::Querying::NotFound` if there are zero matches, and
  # `Grant::Querying::NotUnique` if there is more than one. Use it when business
  # logic guarantees exactly one row should match.
  #
  # ```
  # User.where(email: "a@example.com").sole # => #<User ...> or raises
  # ```
  def sole : Model
    results = self.select

    if results.size == 0
      raise Grant::Querying::NotFound.new("No record found")
    elsif results.size == 1
      results.first
    else
      raise Grant::Querying::NotUnique.new("Multiple records found (expected exactly one)")
    end
  end

  # Loads every matching record and calls `destroy` on each, firing callbacks.
  #
  # Unlike `delete_all`/`delete`, this instantiates the records and runs their
  # destroy callbacks (and dependent-association handling). Returns the number
  # of records successfully destroyed (`Int32`).
  #
  # ```
  # User.where(active: false).destroy_all # => 3
  # ```
  def destroy_all : Int32
    Model.guard_writes!
    records = self.select
    count = 0
    records.each do |record|
      if record.destroy
        count += 1
      end
    end
    count
  end

  # Issues a single `DELETE` for the current conditions, skipping callbacks.
  #
  # Low-level delete: it runs one DELETE statement and does NOT load records or
  # fire destroy callbacks. For chunked, rows-affected-returning deletes use
  # `delete_all`; to run destroy callbacks use `destroy_all`.
  #
  # ```
  # User.where(active: false).delete
  # ```
  def delete
    Model.guard_writes!
    Model.mark_write_operation
    assembler.delete
  end

  # Sets `updated_at` (and any extra *fields*) to *time* for all matching rows.
  #
  # Runs a single UPDATE in the database without loading records or firing
  # callbacks. *fields* lists additional timestamp columns to bump alongside
  # `updated_at`; *time* defaults to now in the configured default timezone.
  #
  # Returns the number of rows affected (`Int64`).
  #
  # ```
  # User.where(active: true).touch_all                # bump updated_at
  # User.where(active: true).touch_all(:last_seen_at) # also bump last_seen_at
  # ```
  def touch_all(*fields, time : Time = Time.local(Grant.settings.default_timezone)) : Int64
    Model.guard_writes!
    Model.mark_write_operation
    assembler.touch_all(fields, time: time)
  end

  # Executes a `COUNT(*)` for the current conditions and returns the row count.
  #
  # Counts in the database (no rows are hydrated). A `none` relation returns `0`.
  # Routes through IN-list chunking and the index-hint fallback like `select`.
  #
  # ```
  # User.where(active: true).count # => 42
  # ```
  def count : Int64
    return 0_i64 if is_none?

    if should_chunk_in?
      return chunked_count
    end

    with_index_hint_fallback do |q|
      q.count_single
    end
  end

  # Executes a single COUNT (no IN-chunking). Used by the chunked/fallback paths.
  protected def count_single : Int64
    result = assembler.count.run
    case result
    when Int64
      result
    when Array(Int64)
      result.sum
    else
      0_i64
    end
  end

  # Returns `true` if the current conditions match any row, otherwise `false`.
  #
  # Runs an efficient existence check (no rows hydrated). A `none` relation is
  # always `false`.
  #
  # ```
  # User.where(email: "a@example.com").exists? # => true/false
  # ```
  def exists? : Bool
    return false if is_none?
    assembler.exists?.run
  end

  # Returns the number of matching records. Alias for `count`.
  #
  # ```
  # User.where(active: true).size # => 42
  # ```
  def size
    count
  end

  # Executes the query and yields each matching record (Enumerable support).
  #
  # Because `Builder` includes `Enumerable(Model)`, defining `each` gives the
  # whole chain `map`, `select`, `reduce`, etc. directly — no `.select`/`.all`
  # needed first.
  #
  # ```
  # User.where(active: true).each { |user| puts user.email }
  # User.where(active: true).map(&.email) # Enumerable, via each
  # ```
  def each(& : Model ->) : Nil
    self.select.each do |record|
      yield record
    end
  end

  # Plucks the primary key values for the relation.
  #
  # Mirrors ActiveRecord's `ids`. Reuses the `pluck` machinery, projecting only
  # the model's primary key column, and returns the values as a typed array.
  #
  # ```
  # User.where(active: true).ids # => [1, 2, 3]
  # User.ids                     # => [1, 2, 3, 4, ...]
  # ```
  def ids : Array(Grant::Columns::Type)
    return [] of Grant::Columns::Type if is_none?

    if should_chunk_in?
      return chunked_ids
    end

    with_index_hint_fallback do |q|
      q.ids_single
    end
  end

  # Executes a single ids query (no IN-chunking). Used by chunked/fallback paths.
  protected def ids_single : Array(Grant::Columns::Type)
    # Reuse the pluck machinery, projecting just the primary key column. The
    # primary key name is a runtime String, so drive pluck_sql/Pluck directly
    # (the public `pluck` takes Symbol splat fields, unavailable from a String).
    field_names = [Model.primary_name]
    pk_assembler = assembler
    sql = pk_assembler.pluck_sql(field_names)
    Grant::Query::Executor::Pluck(Model).new(sql, pk_assembler.numbered_parameters, field_names).run.map(&.first)
  end

  # Iterates over the relation in batches, yielding each record individually.
  #
  # Chainable version of the class-level `find_each` — runs against the
  # relation's current WHERE/ORDER/etc. Built on top of `in_batches`, so it uses
  # primary-key cursor pagination and is memory-friendly for large result sets.
  #
  # ```
  # User.where(active: true).find_each(batch_size: 500) do |user|
  #   process(user)
  # end
  # ```
  def find_each(batch_size : Int32 = 1000, start : Int64? = nil, finish : Int64? = nil, order : Symbol = :asc, &block : Model ->) : Nil
    return if is_none?
    in_batches(of: batch_size, start: start, finish: finish, order: order) do |batch|
      batch.each { |record| yield record }
    end
  end

  # Iterates over the relation in batches, yielding each batch as an Array.
  #
  # Chainable version of the class-level `find_in_batches`. Thin alias over
  # `in_batches` for ActiveRecord naming parity.
  #
  # ```
  # User.where(active: true).find_in_batches(batch_size: 500) do |batch|
  #   bulk_process(batch)
  # end
  # ```
  def find_in_batches(batch_size : Int32 = 1000, start : Int64? = nil, finish : Int64? = nil, order : Symbol = :asc, &block : Array(Model) ->) : Nil
    return if is_none?
    in_batches(of: batch_size, start: start, finish: finish, order: order) do |batch|
      yield batch
    end
  end

  # Marks *associations* to be loaded with the query, avoiding N+1 queries. Returns `self`.
  #
  # `includes` lets Grant choose the loading strategy (typically a separate
  # query per association, like `preload`). Use `eager_load` to force a JOIN.
  # Records are loaded when the query executes (`select`/`first`/iteration).
  #
  # ```
  # # assuming `User has_many :posts`
  # User.where(active: true).includes(:posts).each do |user|
  #   user.posts # already loaded, no extra query per user
  # end
  # ```
  def includes(*associations) : self
    associations.each do |assoc|
      @includes_associations << assoc
    end
    self
  end

  # :ditto:
  #
  # Nested form — keyword arguments name a parent association mapped to its
  # nested association(s) to also load.
  #
  # ```
  # # load each user's posts, and each post's comments
  # User.all.includes(posts: :comments)
  # User.all.includes(posts: [:comments, :tags])
  # ```
  def includes(**nested_associations) : self
    nested_associations.each do |name, nested|
      @includes_associations << {name => nested.is_a?(Array) ? nested : [nested]}
    end
    self
  end

  # Loads *associations* via separate queries (one per association). Returns `self`.
  #
  # Like `includes` but always uses the separate-query strategy (never a JOIN),
  # which avoids row multiplication for has_many associations.
  #
  # ```
  # User.where(active: true).preload(:posts)
  # ```
  def preload(*associations) : self
    associations.each do |assoc|
      @preload_associations << assoc
    end
    self
  end

  # :ditto:
  #
  # Nested form — keyword arguments map a parent association to its nested
  # association(s) to also preload.
  #
  # ```
  # User.all.preload(posts: :comments)
  # ```
  def preload(**nested_associations) : self
    nested_associations.each do |name, nested|
      @preload_associations << {name => nested.is_a?(Array) ? nested : [nested]}
    end
    self
  end

  # Loads *associations* with a single JOIN against the main query. Returns `self`.
  #
  # Forces the JOIN strategy (in contrast to `preload`'s separate queries). Best
  # when you also want to filter or order on the joined table in the same query.
  #
  # ```
  # User.where(active: true).eager_load(:posts)
  # ```
  def eager_load(*associations) : self
    associations.each do |assoc|
      @eager_load_associations << assoc
    end
    self
  end

  # :ditto:
  #
  # Nested form — keyword arguments map a parent association to its nested
  # association(s) to also eager-load.
  #
  # ```
  # User.all.eager_load(posts: :comments)
  # ```
  def eager_load(**nested_associations) : self
    nested_associations.each do |name, nested|
      @eager_load_associations << {name => nested.is_a?(Array) ? nested : [nested]}
    end
    self
  end

  # Create a new query builder for OR conditions.
  #
  # Example:
  # ```
  # User.where(active: true)
  #   .or { |q| q.where(role: "admin") }
  #   .or { |q| q.where.gt(:level, 10) }
  # # SQL: WHERE active = true OR (role = 'admin') OR (level > 10)
  # ```
  #
  # Returns `self`.
  def or(&) : self
    or_builder = self.class.new(@db_type, :or)
    yield or_builder

    # Add the OR conditions as a group
    if or_builder.where_fields.any?
      # Build the OR clause directly without creating assembler
      or_clauses = or_builder.where_fields.map_with_index do |field, idx|
        stmt = case field
               when NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type)
                 field[:stmt]
               when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
                 field[:stmt]
               when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
                 # Simple operator to SQL mapping for OR clauses
                 case field[:operator]
                 when :eq    then "#{field[:field]} = ?"
                 when :neq   then "#{field[:field]} != ?"
                 when :gt    then "#{field[:field]} > ?"
                 when :lt    then "#{field[:field]} < ?"
                 when :gteq  then "#{field[:field]} >= ?"
                 when :lteq  then "#{field[:field]} <= ?"
                 when :in    then "#{field[:field]} IN (?)"
                 when :nin   then "#{field[:field]} NOT IN (?)"
                 when :like  then "#{field[:field]} LIKE ?"
                 when :nlike then "#{field[:field]} NOT LIKE ?"
                 else
                   raise "Unsupported operator in OR clause: #{field[:operator]}"
                 end
               else
                 raise "Unknown where field type"
               end

        if idx == 0
          stmt
        else
          "#{field[:join].to_s.upcase} #{stmt}"
        end
      end.join(" ")

      @where_fields << {
        join:   :or,
        stmt:   "(#{or_clauses})",
        values: collect_group_values(or_builder.where_fields),
      }
    end

    self
  end

  # Support for NOT conditions - negates a group of conditions.
  #
  # Example:
  # ```
  # User.not { |q| q.where(status: "banned").where(active: false) }
  # # SQL: WHERE NOT (status = 'banned' AND active = false)
  # ```
  #
  # Returns `self`.
  def not(&) : self
    not_builder = self.class.new(@db_type)
    yield not_builder

    # Add the NOT conditions as a negated group
    if not_builder.where_fields.any?
      # Build the NOT clause directly without creating assembler
      not_clauses = not_builder.where_fields.map_with_index do |field, idx|
        stmt = case field
               when NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type)
                 field[:stmt]
               when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
                 field[:stmt]
               when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
                 # Simple operator to SQL mapping for NOT clauses
                 case field[:operator]
                 when :eq    then "#{field[:field]} = ?"
                 when :neq   then "#{field[:field]} != ?"
                 when :gt    then "#{field[:field]} > ?"
                 when :lt    then "#{field[:field]} < ?"
                 when :gteq  then "#{field[:field]} >= ?"
                 when :lteq  then "#{field[:field]} <= ?"
                 when :in    then "#{field[:field]} IN (?)"
                 when :nin   then "#{field[:field]} NOT IN (?)"
                 when :like  then "#{field[:field]} LIKE ?"
                 when :nlike then "#{field[:field]} NOT LIKE ?"
                 else
                   raise "Unsupported operator in NOT clause: #{field[:operator]}"
                 end
               else
                 raise "Unknown where field type"
               end

        if idx == 0
          stmt
        else
          "#{field[:join].to_s.upcase} #{stmt}"
        end
      end.join(" ")

      @where_fields << {
        join:   :and,
        stmt:   "NOT (#{not_clauses})",
        values: collect_group_values(not_builder.where_fields),
      }
    end

    self
  end

  # Collects all parameter values from a sub-builder's where_fields in order.
  # Used by grouped or { } and not { } block methods to preserve bind values.
  private def collect_group_values(fields : Array(WhereField)) : Array(Grant::Columns::Type)
    result = [] of Grant::Columns::Type
    fields.each do |field|
      case field
      when NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type)
        result << field[:value] unless field[:value].nil?
      when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
        result.concat(field[:values])
      when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
        next if field[:value].nil?
        val = field[:value]
        # For IN/NOT IN the value is a typed array — store it as-is (the assembler
        # will expand it into individual bind parameters).
        result << val
      end
    end
    result
  end

  # Delete all records matching the query.
  #
  # When a `where(col: array)` exceeds the IN-list chunk limit, the conditions
  # are chunked and each DELETE runs in a single transaction (see
  # `chunked_delete_all`); the summed rows_affected is returned.
  def delete_all : Int64
    Model.guard_writes!

    if should_chunk_in?
      return chunked_delete_all
    end

    delete_all_single
  end

  # Executes a single DELETE (no IN-chunking). Used by the chunked path.
  protected def delete_all_single : Int64
    result = assembler.delete
    result.rows_affected
  end

  # Merge another query's conditions into this one.
  #
  # Combines WHERE conditions with AND, and takes the merged query's
  # ORDER BY, LIMIT, and OFFSET if they are set.
  #
  # Example:
  # ```
  # active = User.where(active: true)
  # admins = User.where(role: "admin")
  # active_admins = active.merge(admins)
  # # WHERE active = true AND role = 'admin'
  # ```
  def merge(other : self) : self
    # Merge where conditions
    other.where_fields.each do |field|
      @where_fields << field
    end

    # Merge order fields (other's order takes precedence if both have orders)
    if other.order_fields.any?
      @order_fields = other.order_fields
    end

    # Merge group fields
    other.group_fields.each do |field|
      @group_fields << field unless @group_fields.includes?(field)
    end

    # Use other's limit/offset if set
    @limit = other.limit if other.limit
    @offset = other.offset if other.offset

    # Merge associations
    @eager_load_associations.concat(other.eager_load_associations).uniq!
    @preload_associations.concat(other.preload_associations).uniq!
    @includes_associations.concat(other.includes_associations).uniq!

    # Use other's lock mode if set
    @lock_mode = other.lock_mode if other.lock_mode

    # Merge join clauses
    other.join_clauses.each do |jc|
      @join_clauses << jc unless @join_clauses.includes?(jc)
    end

    # Merge distinct flag
    @distinct = true if other.distinct?

    # Merge having clauses
    other.having_clauses.each do |hc|
      @having_clauses << hc
    end

    # Merge none flag
    @is_none = true if other.is_none?

    self
  end

  # Create a copy of this query.
  #
  # Useful for creating query variations without modifying the original.
  #
  # Example:
  # ```
  # base_query = User.where(active: true).order(name: :asc)
  # admins = base_query.dup.where(role: "admin")
  # recent = base_query.dup.where.gteq(:created_at, 7.days.ago)
  # ```
  def dup : self
    new_query = self.class.new(@db_type, @boolean_operator)

    # Copy all fields
    @where_fields.each { |f| new_query.where_fields << f }
    @order_fields.each { |f| new_query.order_fields << f }
    @group_fields.each { |f| new_query.group_fields << f }

    new_query.limit(@limit) if @limit
    new_query.offset(@offset) if @offset

    @eager_load_associations.each { |a| new_query.eager_load_associations << a }
    @preload_associations.each { |a| new_query.preload_associations << a }
    @includes_associations.each { |a| new_query.includes_associations << a }

    if lock_mode = @lock_mode
      new_query.lock(lock_mode)
    end

    # Copy join clauses
    @join_clauses.each { |jc| new_query.join_clauses << jc }

    # Copy distinct flag
    new_query.distinct if @distinct

    # Copy having clauses
    @having_clauses.each { |hc| new_query.having_clauses << hc }

    # Copy none flag
    new_query.none if @is_none

    # Copy select columns
    if sc = @select_columns
      new_query.select_columns = sc.dup
    end

    # Copy large-table toolkit state: index hints, IN-chunk override, annotation.
    @index_hints.each { |h| new_query.index_hints << h }
    new_query.copy_scale_state_from(self)

    new_query
  end

  # Add a subquery condition
  private def and_subquery(field : String, subquery : Builder)
    sql = subquery.assembler.select.raw_sql
    @where_fields << {join: :and, stmt: "#{field} IN (#{sql})", value: nil}
    self
  end

  # Restricts the columns included in the SELECT list.
  #
  # Works for both model-loading queries and IN subqueries.
  # Hydration reads columns by name, so unselected columns remain nil
  # on the returned model instances (their Crystal default for nilable types).
  #
  # WARNING: Do not call `save` on a projected record. Unselected columns are
  # nil in memory and will be written back to the database as nil, destroying
  # their stored values. Treat projected records as read-only.
  #
  # Example:
  # ```
  # # Model-loading: only id and name are fetched; other columns are nil
  # User.where(active: true).select(:id, :name).select
  #
  # # Subquery: only the id column is projected for the IN clause
  # admin_ids = User.where(role: "admin").select(:id)
  # Post.where(user_id: admin_ids)
  # ```
  def select(*columns : Symbol) : self
    @select_columns = columns.map(&.to_s).to_a
    self
  end
end
