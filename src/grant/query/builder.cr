require "digest/md5"
require "../columns"
require "../async"
require "./where_chain"
require "./batches"
require "./finders"

# Lazy, chainable SQL query builder returned by `Model.where`, `Model.order`, etc.
#
# A `Builder` accumulates query components (WHERE/ORDER/GROUP BY/LIMIT/…) and
# does **not** touch the database until a terminal method is called. Chain
# methods never change the receiver: each returns a new relation (sharing its
# clause arrays copy-on-write), so a stored relation can be reused safely and
# calls compose left-to-right. The `name!` variants (`where!`, `order!`, …)
# mutate in place for callers that own the relation:
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
#
# # Reuse is safe: chaining never changes `query`.
# admins = query.where(role: "admin")
# ```
#
# Iterating a relation (`each`, `to_a`, `records`, `load`) memoizes its records,
# so `empty?`/`size`/`first` on a loaded relation cost no SQL. `reset` and
# `reload` discard the memo, and any chain method returns an unloaded relation.
#
# Because `Builder` includes `Enumerable(Model)`, collection methods (`map`,
# `select`, `reduce`, `each`, …) work directly on a chain without first calling
# `.select`/`.all`.
#
# Boolean logic can be grouped with the block forms `or { |q| ... }` and
# `not { |q| ... }`, or chained inline with `and`/`or`. Advanced operators
# (`like`, `gt`, `not_in`, …) are available via the no-argument `where`, which
# returns a `WhereChain`.
module Grant::Query
  alias WhereField = NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type) |
                     NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type) |
                     NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))

  # The empty clause lists every new relation starts with. They are shared by
  # all relations and never written: a relation's `@shared_arrays` bit for a
  # list is set while it still holds one of these, so the first write goes
  # through `own_<list>` and copies it. A relation that adds only a WHERE
  # therefore never allocates its (empty) ORDER, GROUP, JOIN, HAVING or
  # association lists.
  module EmptyClauses
    WHERE_FIELDS               = [] of Grant::Query::WhereField
    DEFAULT_SCOPE_WHERE_FIELDS = [] of Grant::Query::WhereField
    ORDER_FIELDS               = [] of NamedTuple(field: String, direction: Grant::Query::Builder::Sort)
    GROUP_FIELDS               = [] of NamedTuple(field: String)
    JOIN_CLAUSES               = [] of NamedTuple(type: Symbol, table: String, on: String)
    HAVING_CLAUSES             = [] of NamedTuple(stmt: String, value: Grant::Columns::Type)
    INCLUDES_ASSOCIATIONS      = [] of Grant::Includes
    PRELOAD_ASSOCIATIONS       = [] of Grant::Includes
    EAGER_LOAD_ASSOCIATIONS    = [] of Grant::Includes
    INDEX_HINTS                = [] of Grant::Query::IndexHint
    OPTIMIZER_HINTS            = [] of String

    # True while every shared list is still empty. A list that has been
    # written through the wrong path would show up here.
    def self.untouched? : Bool
      WHERE_FIELDS.empty? && DEFAULT_SCOPE_WHERE_FIELDS.empty? && ORDER_FIELDS.empty? &&
        GROUP_FIELDS.empty? && JOIN_CLAUSES.empty? && HAVING_CLAUSES.empty? &&
        INCLUDES_ASSOCIATIONS.empty? && PRELOAD_ASSOCIATIONS.empty? &&
        EAGER_LOAD_ASSOCIATIONS.empty? && INDEX_HINTS.empty? && OPTIMIZER_HINTS.empty?
    end
  end
end

class Grant::Query::Builder(Model)
  include Grant::Async::QueryMethods(Model)
  include Enumerable(Model)
  include Grant::Query::Batches(Model)
  include Grant::Query::Finders(Model)

  enum DbType
    Mysql
    Sqlite
    Pg
  end

  # Direction of one ORDER BY term. `Raw` marks a term whose `field` is a
  # complete SQL expression (direction included) that is emitted as written.
  enum Sort
    Ascending
    Descending
    AscendingNullsFirst
    AscendingNullsLast
    DescendingNullsFirst
    DescendingNullsLast
    Raw

    # `true` for every descending member, whatever its NULL placement.
    def sorts_descending? : Bool
      descending? || descending_nulls_first? || descending_nulls_last?
    end

    # Where NULLs sort, `:first` or `:last`, or `nil` for the adapter default.
    def nulls_placement : Symbol?
      if ascending_nulls_first? || descending_nulls_first?
        :first
      elsif ascending_nulls_last? || descending_nulls_last?
        :last
      end
    end

    # The opposite direction, with NULL placement flipped the way
    # ActiveRecord's `reverse_order` does. A `Raw` term stays `Raw`; its SQL is
    # reversed by `Grant::Query::OrderSupport.reverse_raw`.
    def reverse : Sort
      case self
      when Ascending            then Descending
      when Descending           then Ascending
      when AscendingNullsFirst  then DescendingNullsLast
      when AscendingNullsLast   then DescendingNullsFirst
      when DescendingNullsFirst then AscendingNullsLast
      when DescendingNullsLast  then AscendingNullsFirst
      else                           self
      end
    end
  end

  alias WhereField = Grant::Query::WhereField
  alias CountResult = Int64 | Hash(Grant::Columns::Type, Int64) | Hash(Array(Grant::Columns::Type), Int64)
  alias AssociationQuery = Grant::Includes

  getter db_type : DbType
  getter where_fields : Array(WhereField) = Grant::Query::EmptyClauses::WHERE_FIELDS
  getter default_scope_where_fields : Array(WhereField) = Grant::Query::EmptyClauses::DEFAULT_SCOPE_WHERE_FIELDS
  getter order_fields : Array(NamedTuple(field: String, direction: Sort)) = Grant::Query::EmptyClauses::ORDER_FIELDS
  getter group_fields : Array(NamedTuple(field: String)) = Grant::Query::EmptyClauses::GROUP_FIELDS
  getter offset : Int64?
  getter limit : Int64?
  getter eager_load_associations : Array(Grant::Includes) = Grant::Query::EmptyClauses::EAGER_LOAD_ASSOCIATIONS
  getter preload_associations : Array(Grant::Includes) = Grant::Query::EmptyClauses::PRELOAD_ASSOCIATIONS
  getter includes_associations : Array(Grant::Includes) = Grant::Query::EmptyClauses::INCLUDES_ASSOCIATIONS
  getter lock_mode : Grant::Locking::LockMode?
  property select_columns : Array(String)?

  # Join clauses for INNER JOIN and LEFT JOIN operations.
  getter join_clauses : Array(NamedTuple(type: Symbol, table: String, on: String)) = Grant::Query::EmptyClauses::JOIN_CLAUSES

  # Flag for SELECT DISTINCT queries.
  getter? distinct : Bool = false

  # Having clauses for aggregate filtering after GROUP BY.
  getter having_clauses : Array(NamedTuple(stmt: String, value: Grant::Columns::Type)) = Grant::Query::EmptyClauses::HAVING_CLAUSES

  # Flag for null relation (none) — short-circuits to empty results.
  getter? is_none : Bool = false
  getter? strict_loading : Bool = false

  # Copy-on-write bookkeeping: one bit per array ivar (see `own_*`). A set bit
  # means the array may be referenced by another relation and must be copied
  # before it is written to. Declared next to the Bool flags so they pack into
  # one word (every chain step copies the whole relation).
  @shared_arrays : UInt16 = 0x3FF_u16

  # Declared here, beside the other flags, so it packs into the same word; the
  # reader and writer are in `readonly.cr`.
  @readonly : Bool = false

  # Memoized result of `load`. Cleared by every mutation and by `reset`.
  @records : Array(Model)?

  # Memoized `cache_version`, cleared together with `@records`.
  @cache_version : String?

  ALL_ARRAYS_SHARED = 0x3FF_u16

  def initialize(@db_type, @boolean_operator = :and)
  end

  {% for pair in [{"where_fields", 1, "WHERE_FIELDS"}, {"default_scope_where_fields", 2, "DEFAULT_SCOPE_WHERE_FIELDS"}, {"order_fields", 4, "ORDER_FIELDS"}, {"group_fields", 8, "GROUP_FIELDS"}, {"join_clauses", 16, "JOIN_CLAUSES"}, {"having_clauses", 32, "HAVING_CLAUSES"}, {"includes_associations", 64, "INCLUDES_ASSOCIATIONS"}, {"preload_associations", 128, "PRELOAD_ASSOCIATIONS"}, {"eager_load_associations", 256, "EAGER_LOAD_ASSOCIATIONS"}, {"index_hints", 512, "INDEX_HINTS"}] %}
    {% name = pair[0].id %}
    {% bit = pair[1] %}
    # Returns the writable `{{name}}` array, copying it first when another
    # relation still shares it. Every in-place write goes through here.
    #
    # :nodoc:
    def own_{{name}}
      if (@shared_arrays & {{bit}}_u16) != 0_u16
        # Room for the element the caller is about to add, so the write does
        # not reallocate the buffer it was just given.
        writable = @{{name}}.class.new(@{{name}}.size + 1)
        writable.concat(@{{name}})
        @{{name}} = writable
        @shared_arrays &= ~{{bit}}_u16
      end
      reset_load_state
      @{{name}}
    end

    # Replaces `{{name}}` with the shared empty list.
    #
    # :nodoc:
    def clear_{{name}} : Nil
      @{{name}} = Grant::Query::EmptyClauses::{{pair[2].id}}
      @shared_arrays |= {{bit}}_u16
      reset_load_state
    end
  {% end %}

  # Drops memoized records so the next read runs a fresh query.
  private def reset_load_state : Nil
    @records = nil
    @cache_version = nil
  end

  # Returns a copy of this relation that shares its clause arrays with the
  # receiver until either side writes to one (copy-on-write). This is what
  # every non-bang chain method starts from, so chaining allocates one small
  # object plus a copy of only the arrays the step touches.
  #
  # The copy has the receiver's runtime class (named-scope relations, sharded
  # builders). Builder's own state is a shallow memory copy; a subclass that
  # adds instance variables carries them over in `copy_subclass_state_from`.
  def dup : self
    chain_copy
  end

  # Same as `dup`; the name states the intent at chain-method call sites.
  protected def chain_copy : self
    @shared_arrays = ALL_ARRAYS_SHARED
    copy = self.class.allocate
    copy.as(Void*).copy_from(self.as(Void*), instance_sizeof(Grant::Query::Builder(Model)))
    copy.copy_subclass_state_from(self)
    copy.forget_copied_state
    copy
  end

  # Hook for subclasses that declare their own instance variables: copy them
  # from *source* into the receiver, a fresh copy of the same class.
  #
  # :nodoc:
  protected def copy_subclass_state_from(source : Grant::Query::Builder(Model)) : Nil
  end

  # :nodoc:
  protected def forget_copied_state : Nil
    @records = nil
    @cache_version = nil
    @_cached_assembler = nil
    # The copy records its own column-keyed raw clauses from here on.
    if raw_columns = @raw_where_columns
      @raw_where_columns = raw_columns.dup
    end
  end

  # Returns a copy whose WHERE clauses are recorded as default-scope clauses
  # (the ones `unscope(:where)` leaves alone). Used when a model builds its
  # `current_scope` from `default_scope` and STI filters.
  #
  # :nodoc:
  def promote_where_to_default_scope : self
    copy = chain_copy
    copy.own_default_scope_where_fields.concat(copy.where_fields)
    copy.clear_where_fields
    copy
  end

  # Returns a copy with strict loading set (default `true`). Records loaded
  # from the copy raise when an unloaded association is read.
  def strict_loading(value : Bool = true) : self
    chain_copy.strict_loading!(value)
  end

  def strict_loading!(value : Bool = true) : self
    reset_load_state
    @strict_loading = value
    self
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
  # - `Array` → `column IN (...)` (a nil member also matches NULL)
  # - `Range` → `column >= begin AND column <= end` (`<` for an exclusive end);
  #   a beginless or endless range keeps only its one bound
  # - a nested `NamedTuple`/`Hash` → conditions on a joined table (`posts: {published: true}`)
  # - a record (or array of records) under a `belongs_to` name → its foreign key
  #   (and type column when polymorphic)
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
  # User.where(id: 1..10)                            # id >= 1 AND id <= 10
  # User.where(id: ..10)                             # id <= 10
  # ```
  def where!(**matches) : self
    where!(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `where(**matches)` — accepts a pre-built collection
  # of column/value pairs.
  #
  # ```
  # User.where({active: true, email: "a@example.com"})
  # ```
  def where!(matches) : self
    matches.each { |field, value| add_condition(:and, field.to_s, value) }
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
  def where!(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type) : self
    and!(field: resolve_column_alias(field.to_s), operator: operator, value: value)
  end

  # Adds a raw SQL condition *stmt*, ANDed onto the query.
  #
  # Use a `?` placeholder and pass *value* to bind it safely.
  #
  # ```
  # User.where("LENGTH(email) > ?", 20)
  # User.where("active = true") # no bind value
  # ```
  def where!(stmt : String) : self
    and!(stmt)
  end

  def where!(stmt : String, value : Nil) : self
    and!(stmt, value)
  end

  def where!(stmt : String, values : Array) : self
    and!(stmt, values)
  end

  def where!(stmt : String, value : Grant::Columns::Type) : self
    and!(stmt, value)
  end

  def where!(stmt : String, first, second, *rest) : self
    values = [] of Grant::Columns::Type
    values << first.as(Grant::Columns::Type) << second.as(Grant::Columns::Type)
    rest.each { |value| values << value.as(Grant::Columns::Type) }
    and!(stmt, values)
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
  def and!(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type) : self
    own_where_fields << {join: :and, field: field.to_s, operator: operator, value: value}

    self
  end

  # Adds a raw SQL AND condition *stmt*, optionally binding *value* to a `?`. Returns `self`.
  #
  # ```
  # User.where(active: true).and("LENGTH(email) > ?", 10)
  # ```
  def and!(stmt : String) : self
    own_where_fields << {join: :and, stmt: stmt, value: nil.as(Grant::Columns::Type)}
    self
  end

  def and!(stmt : String, value : Nil) : self
    own_where_fields << {join: :and, stmt: stmt, values: [value.as(Grant::Columns::Type)]}
    self
  end

  def and!(stmt : String, value : Grant::Columns::Type) : self
    if values = raw_bind_values(value)
      own_where_fields << {join: :and, stmt: stmt, values: values}
    else
      own_where_fields << {join: :and, stmt: stmt, value: value}
    end

    self
  end

  def and!(stmt : String, values : Array) : self
    bind_values = [] of Grant::Columns::Type
    values.each { |item| bind_values << item.as(Grant::Columns::Type) }
    own_where_fields << {join: :and, stmt: stmt, values: bind_values}
    self
  end

  def and!(stmt : String, first, second, *rest) : self
    values = [] of Grant::Columns::Type
    values << first.as(Grant::Columns::Type) << second.as(Grant::Columns::Type)
    rest.each { |value| values << value.as(Grant::Columns::Type) }
    and!(stmt, values)
  end

  # Adds a structured `IN` or `NOT IN` predicate from a possibly nilable list.
  # This overload keeps nil inside the list semantics without passing an
  # unsupported Array(Union(...)) value through the DB driver.
  def and_in!(field : Symbol | String, values : Array, negated : Bool = false) : self
    and_array(field.to_s, negated ? :nin : :in, values)
  end

  private def and_array(field : String, operator : Symbol, values : Array) : self
    has_nil = values.any?(Nil)
    values_without_nil = values.compact

    if values_without_nil.empty?
      if has_nil
        null_predicate = "#{structured_field_sql(field)} IS #{operator == :nin ? "NOT " : ""}NULL"
        own_where_fields << {join: :and, stmt: null_predicate, value: nil.as(Grant::Columns::Type)}
        register_raw_where_column(null_predicate, field)
      else
        own_where_fields << {join: :and, stmt: operator == :nin ? "1=1" : "1=0", value: nil.as(Grant::Columns::Type)}
      end
      return self
    end

    unless has_nil
      own_where_fields << {join: :and, field: field, operator: operator, value: values_without_nil.as(Grant::Columns::Type)}
      return self
    end

    safe_field = structured_field_sql(field)
    bind_values = [] of Grant::Columns::Type
    values_without_nil.each { |item| bind_values << item.as(Grant::Columns::Type) }
    placeholders = Array.new(bind_values.size, "?").join(", ")
    predicate = if operator == :nin
                  "(#{safe_field} NOT IN (#{placeholders}) AND #{safe_field} IS NOT NULL)"
                else
                  "(#{safe_field} IN (#{placeholders}) OR #{safe_field} IS NULL)"
                end
    own_where_fields << {join: :and, stmt: predicate, values: bind_values}
    register_raw_where_column(predicate, field)
    self
  end

  private def raw_bind_values(value : Grant::Columns::Type) : Array(Grant::Columns::Type)?
    if value.is_a?(Array)
      values = [] of Grant::Columns::Type
      value.each { |item| values << item.as(Grant::Columns::Type) }
      values
    end
  end

  # Adds AND equality/set/range conditions from keyword arguments. Synonym of `where(**matches)`. Returns `self`.
  #
  # ```
  # User.where(active: true).and(email: "a@example.com")
  # ```
  def and!(**matches) : self
    and!(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `and(**matches)`.
  def and!(matches) : self
    matches.each { |field, value| add_condition(:and, field.to_s, value) }
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
  def or!(**matches) : self
    or!(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `or(**matches)`.
  def or!(matches) : self
    matches.each { |field, value| add_condition(:or, field.to_s, value) }
    self
  end

  # Adds an OR condition with an explicit *operator*. See `where(field, operator, value)`. Returns `self`.
  #
  # ```
  # User.where(active: true).or(:id, :lt, 10)
  # # => WHERE active = true OR id < 10
  # ```
  def or!(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type) : self
    own_where_fields << {join: :or, field: field.to_s, operator: operator, value: value}

    self
  end

  # Adds a raw SQL OR condition *stmt*, optionally binding *value* to a `?`. Returns `self`.
  #
  # ```
  # User.where(active: true).or("LENGTH(email) > ?", 30)
  # ```
  def or!(stmt : String) : self
    own_where_fields << {join: :or, stmt: stmt, value: nil.as(Grant::Columns::Type)}
    self
  end

  def or!(stmt : String, value : Nil) : self
    own_where_fields << {join: :or, stmt: stmt, values: [value.as(Grant::Columns::Type)]}
    self
  end

  def or!(stmt : String, values : Array) : self
    bind_values = [] of Grant::Columns::Type
    values.each { |item| bind_values << item.as(Grant::Columns::Type) }
    own_where_fields << {join: :or, stmt: stmt, values: bind_values}
    self
  end

  def or!(stmt : String, value : Grant::Columns::Type) : self
    if values = raw_bind_values(value)
      own_where_fields << {join: :or, stmt: stmt, values: values}
    else
      own_where_fields << {join: :or, stmt: stmt, value: value}
    end

    self
  end

  # Adds an OR `IN`/`NOT IN` condition. A nullable array becomes one grouped
  # predicate, so a following condition cannot split its NULL branch.
  def or_in!(field : Symbol | String, values : Array, negated : Bool = false) : self
    or_array(field.to_s, negated ? :nin : :in, values)
  end

  private def or_array(field : String, operator : Symbol, values : Array) : self
    has_nil = values.any?(Nil)
    values_without_nil = values.compact

    if values_without_nil.empty?
      if has_nil
        null_predicate = "#{structured_field_sql(field)} IS #{operator == :nin ? "NOT " : ""}NULL"
        own_where_fields << {join: :or, stmt: null_predicate, value: nil.as(Grant::Columns::Type)}
        register_raw_where_column(null_predicate, field)
      else
        own_where_fields << {join: :or, stmt: operator == :nin ? "1=1" : "1=0", value: nil.as(Grant::Columns::Type)}
      end
      return self
    end

    unless has_nil
      own_where_fields << {join: :or, field: field, operator: operator, value: values_without_nil.as(Grant::Columns::Type)}
      return self
    end

    safe_field = structured_field_sql(field)
    bind_values = [] of Grant::Columns::Type
    values_without_nil.each { |item| bind_values << item.as(Grant::Columns::Type) }
    placeholders = Array.new(bind_values.size, "?").join(", ")
    predicate = if operator == :nin
                  "(#{safe_field} NOT IN (#{placeholders}) AND #{safe_field} IS NOT NULL)"
                else
                  "(#{safe_field} IN (#{placeholders}) OR #{safe_field} IS NULL)"
                end
    own_where_fields << {join: :or, stmt: predicate, values: bind_values}
    register_raw_where_column(predicate, field)
    self
  end

  private def structured_field_sql(field : String) : String
    parts = field.split('.')
    unless parts.size.in?(1..2) && parts.all?(&.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/))
      raise ArgumentError.new("Invalid query field #{field.inspect}")
    end

    column = parts.last
    qualifier = parts.size == 2 ? parts.first : nil
    if qualifier && qualifier != Model.table_name
      # A joined table: check the column against the model behind it when the
      # registry knows one; a raw joined table is only identifier-checked.
      joined = Grant::Query::JoinedColumns.known_column?(Model.name, qualifier, column)
      if joined == false
        raise ArgumentError.new("Unknown query field #{column.inspect} for #{Model.name}")
      end
    else
      unless Model.fields.includes?(column)
        raise ArgumentError.new("Unknown query field #{column.inspect} for #{Model.name}")
      end
    end

    if qualifier
      allowed_qualifiers = [Model.table_name] + @join_clauses.flat_map { |join| Grant::Query::JoinSupport.qualifiers(join) }
      unless allowed_qualifiers.includes?(qualifier)
        raise ArgumentError.new("Unknown query table #{qualifier.inspect} for #{Model.name}")
      end
      "#{Model.quote(qualifier)}.#{Model.quote(column)}"
    elsif !@join_clauses.empty?
      "#{Model.quote(Model.table_name)}.#{Model.quote(column)}"
    else
      Model.quote(column)
    end
  end

  # Appends an ascending ORDER BY on a single *field*. Returns `self`.
  #
  # ```
  # User.order(:email) # => ORDER BY email ASC
  # ```
  def order!(field : Symbol) : self
    own_order_fields << {field: resolve_column_alias(field.to_s), direction: Sort::Ascending}

    self
  end

  # Appends ascending ORDER BY clauses for several *fields* in order. Returns `self`.
  #
  # ```
  # User.order([:active, :email]) # => ORDER BY active ASC, email ASC
  # ```
  def order!(fields : Array(Symbol)) : self
    fields.each do |field|
      order! field
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
  def order!(**dsl) : self
    order!(dsl)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `order(**dsl)`.
  def order!(dsl) : self
    dsl.each do |field, dsl_direction|
      direction = Sort::Ascending

      if dsl_direction == "desc" || dsl_direction == :desc
        direction = Sort::Descending
      end

      own_order_fields << {field: resolve_column_alias(field.to_s), direction: direction}
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
  def group_by!(field : Symbol) : self
    own_group_fields << {field: field.to_s}

    self
  end

  # Appends GROUP BY clauses for several *fields*. Returns `self`.
  #
  # ```
  # User.group_by([:active, :email]) # => GROUP BY active, email
  # ```
  def group_by!(fields : Array(Symbol)) : self
    fields.each do |field|
      group_by! field
    end

    self
  end

  # Appends GROUP BY clauses from keyword-argument keys (values are ignored). Returns `self`.
  #
  # ```
  # User.group_by(active: true) # => GROUP BY active
  # ```
  def group_by!(**dsl) : self
    group_by!(dsl)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `group_by(**dsl)`.
  def group_by!(dsl) : self
    dsl.each do |field, _|
      own_group_fields << {field: field.to_s}
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
  def lock!(mode : Grant::Locking::LockMode = Grant::Locking::LockMode::Update) : self
    reset_load_state
    @lock_clause = nil
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
  def joins!(table : String, *, on : String) : self
    add_join_clause({type: :inner, table: table, on: on})
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
  def joins!(association : Symbol) : self
    add_join_clauses(resolve_association_join(association, :inner))
    self
  end

  # Adds INNER JOINs for several association names at once, optionally with
  # nested associations, resolved through the association registry from the
  # model each level reaches. A has_many chain multiplies rows; pair it with
  # `distinct` when the parent rows are wanted once. A table reached through two
  # different paths is joined under an alias.
  #
  # ```
  # User.joins(posts: :comments)
  # User.joins(posts: [:comments, {likes: :user}])
  # User.joins(:comments, posts: :comments) # comments, then comments_posts
  # ```
  def joins!(*associations : Symbol, **nested) : self
    associations.each { |assoc| joins!(assoc) }
    add_join_clauses(Grant::Query::JoinSupport.resolve_nested(Model, nested, :inner, @join_clauses)) unless nested.empty?
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
  def left_joins!(table : String, *, on : String) : self
    add_join_clause({type: :left, table: table, on: on})
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
  def left_joins!(association : Symbol) : self
    add_join_clauses(resolve_association_join(association, :left))
    self
  end

  # Adds LEFT JOINs for several association names at once, optionally with
  # nested associations.
  def left_joins!(*associations : Symbol, **nested) : self
    associations.each { |assoc| left_joins!(assoc) }
    add_join_clauses(Grant::Query::JoinSupport.resolve_nested(Model, nested, :left, @join_clauses)) unless nested.empty?
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
  private def resolve_association_join(association : Symbol, type : Symbol) : Array(NamedTuple(type: Symbol, table: String, on: String))
    Grant::Query::JoinSupport.resolve(Model, association, type, nil, @join_clauses)
  end

  private def add_eager_load_join(association : Symbol) : Nil
    reflection = Grant::AssociationRegistry.reflection(Model.name, association.to_s)
    raise Grant::AssociationNotFoundError.new(Model.name, association.to_s) unless reflection
    if reflection.polymorphic?
      raise ArgumentError.new("Cannot eager_load polymorphic association #{Model.name}##{association}; use includes or preload")
    end

    if reflection.polymorphic_as
      add_polymorphic_as_eager_load_join(reflection)
      distinct!
      return
    end

    metadata = Grant::AssociationRegistry.get(Model.name, association.to_s)
    raise Grant::AssociationNotFoundError.new(Model.name, association.to_s) unless metadata

    if metadata[:through]
      raise ArgumentError.new("Cannot eager_load through association #{Model.name}##{association}: unresolved through/source metadata") unless add_through_eager_load_join(metadata)
    else
      left_joins!(association)
    end
    distinct!
  end

  # `has_many/has_one ..., as:` joins on the key and on the stored type name.
  private def add_polymorphic_as_eager_load_join(reflection : Grant::Reflection) : Nil
    target_model = reflection.klass
    type_column = reflection.foreign_type || return
    type_name = Model.polymorphic_name.gsub("'", "''")
    on = "#{target_model.quote(target_model.table_name)}.#{target_model.quote(reflection.foreign_key)} = #{Model.quote(Model.table_name)}.#{Model.quote(reflection.primary_key)}" \
         " AND #{target_model.quote(target_model.table_name)}.#{target_model.quote(type_column)} = '#{type_name}'"
    left_joins!(target_model.table_name, on: on)
  end

  private def add_through_eager_load_join(metadata : Grant::AssociationRegistry::AssociationMeta) : Bool
    through_name = metadata[:through]
    source_name = metadata[:source]
    return false unless through_name && source_name

    through_metadata = Grant::AssociationRegistry.get(Model.name, through_name)
    return false unless through_metadata
    source_metadata = Grant::AssociationRegistry.get(through_metadata[:target_class].name, source_name)
    return false unless source_metadata

    through_model = through_metadata[:target_class]
    target_model = metadata[:target_class]
    owner_join = "#{through_model.quote(through_model.table_name)}.#{through_model.quote(through_metadata[:foreign_key])} = #{Model.quote(Model.table_name)}.#{Model.quote(through_metadata[:primary_key])}"
    left_joins!(through_model.table_name, on: owner_join)

    target_join = if source_metadata[:type] == :belongs_to
                    "#{target_model.quote(target_model.table_name)}.#{target_model.quote(source_metadata[:primary_key])} = #{through_model.quote(through_model.table_name)}.#{through_model.quote(source_metadata[:foreign_key])}"
                  else
                    "#{target_model.quote(target_model.table_name)}.#{target_model.quote(source_metadata[:foreign_key])} = #{through_model.quote(through_model.table_name)}.#{through_model.quote(source_metadata[:primary_key])}"
                  end
    left_joins!(target_model.table_name, on: target_join)
    true
  end

  # Sets the query to return only distinct (unique) rows.
  #
  # When enabled, duplicate rows are removed from the result set.
  #
  # ```
  # User.where(active: true).distinct
  # # => SELECT DISTINCT ... FROM users WHERE active = true
  # ```
  def distinct! : self
    reset_load_state
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
  def having!(stmt : String, value : Grant::Columns::Type = nil) : self
    own_having_clauses << {stmt: stmt, value: value}
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
  def none! : self
    reset_load_state
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
  def reorder!(**dsl) : self
    start_reordering!
    order!(**dsl)
  end

  # Clears existing order and replaces with a single field ascending.
  #
  # ```
  # User.order(name: :desc).reorder(:created_at)
  # # => SELECT ... FROM users ORDER BY created_at ASC
  # ```
  def reorder!(field : Symbol) : self
    start_reordering!
    order!(field)
  end

  # Clears existing order and replaces it with several ascending fields.
  #
  # ```
  # User.order(name: :desc).reorder(:created_at, :id)
  # # => ORDER BY created_at ASC, id ASC
  # ```
  def reorder!(*fields : Symbol) : self
    start_reordering!
    fields.each { |field| order!(field) }
    self
  end

  # Clears existing order and replaces it with an array of ascending fields.
  def reorder!(fields : Array(Symbol)) : self
    start_reordering!
    order!(fields)
  end

  # `reorder(nil)` drops the ordering altogether, like ActiveRecord's
  # `reorder(nil)`.
  #
  # ```
  # User.order(:name).reorder(nil) # => no ORDER BY
  # ```
  def reorder!(none : Nil) : self
    start_reordering!
    self
  end

  # Reverses the direction of all existing order clauses.
  #
  # Ascending becomes Descending and vice versa. On an unordered relation the
  # implicit order (the primary key) is reversed, as in ActiveRecord.
  #
  # ```
  # User.order(name: :asc, created_at: :desc).reverse_order
  # # => SELECT ... FROM users ORDER BY name DESC, created_at ASC
  # User.reverse_order # => ORDER BY id DESC
  # ```
  def reverse_order! : self
    reset_load_state
    if @order_fields.empty?
      implicit_order_columns.each do |column|
        own_order_fields << {field: column, direction: Sort::Descending}
      end
      return self
    end

    @order_fields = @order_fields.map { |field| Grant::Query::OrderSupport.reverse(field) }
    @shared_arrays &= ~4_u16
    self
  end

  # Replaces the WHERE conditions on the columns named in *matches* and keeps
  # every other condition, like ActiveRecord's `rewhere`.
  #
  # ```
  # User.where(active: true, role: "admin").rewhere(active: false)
  # # => WHERE role = 'admin' AND active = false
  # ```
  def rewhere!(**matches) : self
    rewhere!(matches)
  end

  # :ditto:
  #
  # Hash/NamedTuple form of `rewhere(**matches)`.
  def rewhere!(matches) : self
    unscope_where_columns!(matches.keys.map(&.to_s).to_a)
    where!(matches)
  end

  # Clears existing column projection and replaces with new columns.
  #
  # Hydration reads by column name, so unselected columns remain nil.
  #
  # ```
  # User.where(active: true).select(:id, :name).reselect(:id, :email).select
  # # => SELECT id, email FROM users WHERE active = ?
  # ```
  def reselect!(*columns : Symbol) : self
    reset_load_state
    @select_columns = columns.map { |column| resolve_column_alias(column.to_s) }.to_a
    self
  end

  # Clears existing GROUP BY and replaces with a new grouping.
  #
  # ```
  # User.group_by(:status).regroup(:department)
  # # => SELECT ... FROM users GROUP BY department
  # ```
  def regroup!(field : Symbol) : self
    clear_group_fields
    group_by!(field)
  end

  # Clears existing GROUP BY and replaces with new groupings.
  #
  # ```
  # User.group_by(:status).regroup(:department, :role)
  # # => SELECT ... FROM users GROUP BY department, role
  # ```
  def regroup!(*fields : Symbol) : self
    clear_group_fields
    fields.each { |f| group_by!(f) }
    self
  end

  # Returns a relation with the named clause components stripped.
  #
  # Mirrors ActiveRecord's `unscope`. Useful for removing parts of an inherited
  # scope while keeping the rest of the chain intact. Recognized components:
  # `:where`, `:order`, `:limit`, `:offset`, `:group` (alias `:group_by`),
  # `:having`, `:joins`, `:left_joins` (alias `:left_outer_joins`), `:select`,
  # `:distinct`, `:lock`, `:readonly`, `:optimizer_hints`, `:from`, `:with`,
  # `:includes`, `:preload`, `:eager_load`, `:strict_loading`, `:annotate`,
  # `:create_with`, `:reordering` and `:extending` (a no-op: a relation holds no
  # extension modules). `unscope(where: :column)` drops the conditions on one
  # column. Default-scope clauses stay, and so do raw SQL string conditions.
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
  def unscope!(*components : Symbol) : self
    record_unscope(components.to_a)
    unscope_components!(components.to_a)
  end

  # Applies `unscope!` for a list of components (shared with `only`).
  protected def unscope_components!(components : Array(Symbol)) : self
    reset_load_state
    components.each do |component|
      case component
      when :where
        clear_where_fields
      when :order
        clear_order_fields
      when :limit
        @limit = nil
      when :offset
        @offset = nil
      when :group, :group_by
        clear_group_fields
      when :having
        clear_having_clauses
      when :joins
        drop_join_clauses!(left: false)
      when :left_joins, :left_outer_joins
        drop_join_clauses!(left: true)
      when :select
        @select_columns = nil
      when :distinct
        @distinct = false
      when :lock
        @lock_mode = nil
        @lock_clause = nil
      when :readonly
        @readonly = false
      when :optimizer_hints
        @optimizer_hints = [] of String
      when :from
        clear_from_source!
      when :with
        clear_common_tables!
      else
        raise ArgumentError.new("unscope: unknown component #{component.inspect}") unless unscope_extra_component!(component)
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
  def offset!(num) : self
    reset_load_state
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
  def limit!(num) : self
    reset_load_state
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
    restrictions = association_restrictions
    records = assembler.select.run
    records.each(&.strict_loading!) if strict_loading?
    records.each(&.readonly!) if readonly?

    # Apply eager loading if any associations are specified
    all_associations = @includes_associations + @preload_associations + @eager_load_associations
    unless all_associations.empty?
      Grant::AssociationLoader.load_associations(records, all_associations, restrictions)
    end

    records
  end

  # Returns a lazy copy of this relation, like ActiveRecord's `relation.all`.
  # Nothing is executed; chain further clauses or iterate to load it. Use
  # `select` (or `to_a`/`records`) to get the matching rows as an `Array`.
  #
  # ```
  # User.where(active: true).all.order(:email) # still a relation
  # User.where(active: true).all.to_a          # => [#<User ...>, ...]
  # ```
  def all : self
    chain_copy
  end

  # Loads the relation once and memoizes the records. Later `each`, `size`,
  # `empty?`, `first` and friends read the memoized records instead of running
  # SQL. Any chain method returns a fresh, unloaded relation.
  #
  # ```
  # users = User.where(active: true).load
  # users.loaded? # => true
  # users.empty?  # => false (no query)
  # ```
  def load : self
    records
    self
  end

  # Returns `true` once `load` (or an iteration) has memoized the records.
  def loaded? : Bool
    !@records.nil?
  end

  # Returns the memoized records, loading them first when needed.
  def records : Array(Model)
    if memoized = @records
      return memoized
    end

    loaded = self.select
    @records = loaded
    loaded
  end

  # Forgets the memoized records; the next read runs SQL again. Returns `self`.
  def reset : self
    reset_load_state
    self
  end

  # Discards the memoized records and loads the relation again.
  def reload : self
    reset
    load
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

  # ActiveRecord-style name for `raw_sql`.
  def to_sql : String
    raw_sql
  end

  # Clause components `only` and `except` understand; the same table `unscope`
  # uses.
  RELATION_COMPONENTS = [:where, :order, :limit, :offset, :group, :having, :joins, :left_joins, :select, :distinct, :lock, :from, :with,
                         :includes, :preload, :eager_load, :strict_loading, :readonly, :optimizer_hints, :annotate, :create_with, :reordering, :extending]

  # Returns a copy that keeps only the named clause *components* and drops the
  # rest. Components are `:where`, `:order`, `:limit`, `:offset`, `:group`,
  # `:having`, `:joins`, `:left_joins`, `:select`, `:distinct`, `:lock`,
  # `:from`, `:with`, the eager-loading lists `:includes`, `:preload` and
  # `:eager_load`, and the flags and settings `:strict_loading`, `:readonly`,
  # `:optimizer_hints`, `:annotate`, `:create_with`, `:reordering` and
  # `:extending`. Default-scope clauses are left alone, as with `unscope`: they
  # are what keeps a soft-delete or tenant filter in place (use `unscoped` to
  # drop them on purpose). Raises `ArgumentError` for an unknown component.
  #
  # ```
  # User.where(active: true).order(:email).limit(5).only(:where)
  # # => WHERE active = ? (no ORDER BY, no LIMIT)
  # ```
  def only(*components : Symbol) : self
    normalized = components.map do |component|
      case component
      when :group_by         then :group
      when :left_outer_joins then :left_joins
      else                        component
      end
    end
    unknown = normalized.reject { |component| RELATION_COMPONENTS.includes?(component) }
    raise ArgumentError.new("only: unknown component #{unknown.first.inspect}") unless unknown.empty?

    dropped = RELATION_COMPONENTS.reject { |component| normalized.includes?(component) }
    chain_copy.unscope_components!(dropped)
  end

  # Returns a copy without the named clause *components* (see `only` for the
  # component list). Same as `unscope`, spelled like ActiveRecord.
  #
  # ```
  # User.where(active: true).order(:email).except(:order)
  # ```
  def except(*components : Symbol) : self
    chain_copy.unscope_components!(components.to_a)
  end

  # Returns a stable key for the query (table name plus a digest of its SQL and
  # bind values). It does not run a query.
  #
  # ```
  # User.where(active: true).cache_key # => "users/query-5f0e..."
  # ```
  def cache_key : String
    query_assembler = assembler
    sql = query_assembler.select.raw_sql
    digest = Digest::MD5.hexdigest("#{sql}|#{query_assembler.numbered_parameters.inspect}")
    "#{Model.table_name}/query-#{digest}"
  end

  # Returns a version string for the current contents of the relation:
  # `"<row count>-<newest updated_at>"`, computed with a single aggregate query
  # and memoized until the relation is reset. Models without an `updated_at`
  # column get the count alone.
  #
  # ```
  # User.where(active: true).cache_version # => "42-20260928120000000000"
  # ```
  def cache_version : String
    if memoized = @cache_version
      return memoized
    end

    return @cache_version = "0" if is_none?

    inner = chain_copy
    inner.clear_order_fields
    version_assembler = inner.assembler
    inner_sql = version_assembler.select.raw_sql
    has_updated_at = Model.fields.includes?("updated_at")
    newest = has_updated_at ? ", MAX(#{Model.quote("updated_at")})" : ""
    sql = Grant::QueryLogs.append("SELECT COUNT(*)#{newest} FROM (#{inner_sql}) AS grant_cache_version")

    count = 0_i64
    newest_value : Grant::Columns::Type = nil
    adapter = Model.adapter
    started = Time.instant
    adapter.open(sql, version_assembler.numbered_parameters, Model.name) do |db|
      db.query(sql, args: adapter.normalize_bind_values(version_assembler.numbered_parameters)) do |rs|
        rs.each do
          count = rs.read(Int64)
          newest_value = rs.read(Grant::Columns::Type) if has_updated_at
        end
      end
    end
    elapsed_ms = (Time.instant - started).total_milliseconds
    Grant::Logs::SQL.debug { "Query executed (#{elapsed_ms}ms) - #{sql} [#{Model.name}] [rows: 1]" }
    Grant::Logs.log_verbose(sql, Time.instant - started, Model.name)

    @cache_version = cache_version_string(count, newest_value)
  end

  private def cache_version_string(count : Int64, newest : Grant::Columns::Type) : String
    stamp = case newest
            when Time
              newest.to_utc.to_s("%Y%m%d%H%M%S%6N")
            when String
              newest.gsub(/[^0-9]/, "")
            else
              ""
            end
    stamp.empty? ? count.to_s : "#{count}-#{stamp}"
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

  # Returns the first record ordered by the implicit order (see
  # `implicit_order_column`; the primary key by default) unless the relation is
  # already ordered. Runs `LIMIT 1` on a copy, so the receiver is unchanged; a
  # loaded relation answers from its memoized records.
  #
  # ```
  # User.where(active: true).order(id: :asc).first # => #<User ...> or nil
  # ```
  def first : Model?
    if memoized = @records
      return memoized.first?
    end

    first_records_from(0, 1).first?
  end

  # Like `first` but raises `Grant::Querying::NotFound` when nothing matches.
  #
  # ```
  # User.where(active: true).first! # => #<User ...> or raises
  # ```
  def first! : Model
    first || raise Grant::Querying::NotFound.new("No record found")
  end

  # Returns up to *n* records from the start of the relation's order.
  #
  # ```
  # User.where(active: true).order(id: :desc).first(3) # => up to 3 users
  # ```
  def first(n : Int32) : Array(Model)
    if memoized = @records
      return memoized.first(n)
    end

    first_records_from(0, n)
  end

  # Returns one record with no ordering applied (`LIMIT 1`), or `nil`.
  #
  # Unlike `first`, `take` adds no `ORDER BY`, so the database may return any
  # matching row.
  def take : Model?
    if memoized = @records
      return memoized.first?
    end

    chain_copy.limit!(1).select.first?
  end

  # Returns up to *n* records with no ordering applied.
  def take(n : Int32) : Array(Model)
    if memoized = @records
      return memoized.first(n)
    end

    chain_copy.limit!(n).select
  end

  # Like `take`, but raises `Grant::Querying::NotFound` when nothing matches.
  def take! : Model
    take || raise Grant::Querying::NotFound.new("No record found")
  end

  # Returns the last matching row by running the relation in reverse order
  # (`ORDER BY` flipped, or the implicit order descending) with `LIMIT 1`.
  def last : Model?
    if memoized = @records
      return memoized.last?
    end

    # Reversing a LIMIT/OFFSET window would read the end of the whole table,
    # so a windowed relation loads its window (at most its limit) instead.
    return ordered_copy.select.last? if limit_or_offset?

    ordered_copy(reverse: true).limit!(1).select.first?
  end

  # Returns the last *n* matching rows in the relation's own order.
  #
  # ```
  # User.order(:id).last(2) # => [user_9, user_10]
  # ```
  def last(n : Int32) : Array(Model)
    if memoized = @records
      return memoized.last(n)
    end

    return ordered_copy.select.last(n) if limit_or_offset?

    ordered_copy(reverse: true).limit!(n).select.reverse!
  end

  # Like `last`, but raises when the relation has no matching records.
  def last! : Model
    last || raise Grant::Querying::NotFound.new("No record found")
  end

  {% for pair in [{"second", 1}, {"third", 2}, {"fourth", 3}, {"fifth", 4}, {"forty_two", 41}] %}
    # Returns the {{pair[0].id}} record of the ordered relation (`LIMIT 1 OFFSET {{pair[1]}}`
    # from the relation's own offset), or `nil` when there are fewer.
    def {{pair[0].id}} : Model?
      nth_record({{pair[1]}})
    end

    # Like `{{pair[0].id}}`, but raises `Grant::Querying::NotFound` when missing.
    def {{pair[0].id}}! : Model
      {{pair[0].id}} || raise Grant::Querying::NotFound.new("No record found")
    end
  {% end %}

  {% for pair in [{"second_to_last", 1}, {"third_to_last", 2}] %}
    # Returns the {{pair[0].id.gsub(/_/, " ")}} record of the ordered relation, counting from the
    # end, or `nil` when there are fewer.
    def {{pair[0].id}} : Model?
      nth_record({{pair[1]}}, reverse: true)
    end

    # Like `{{pair[0].id}}`, but raises `Grant::Querying::NotFound` when missing.
    def {{pair[0].id}}! : Model
      {{pair[0].id}} || raise Grant::Querying::NotFound.new("No record found")
    end
  {% end %}

  private def nth_record(index : Int32, reverse : Bool = false) : Model?
    if reverse
      nth_record_from_end(index)
    elsif memoized = @records
      memoized[index]?
    else
      first_records_from(index, 1).first?
    end
  end

  # Counting from the end (0 = last). A negative Array index would wrap
  # around, so a position before the first record answers `nil`.
  private def nth_record_from_end(index : Int32) : Model?
    if memoized = @records
      position = memoized.size - 1 - index
      return position >= 0 ? memoized[position] : nil
    end

    if limit_or_offset?
      window = ordered_copy.select
      position = window.size - 1 - index
      return position >= 0 ? window[position] : nil
    end

    ordered_copy(reverse: true).offset!(index).limit!(1).select.first?
  end

  # Up to *count* records starting *index* rows into the ordered relation,
  # staying inside the relation's own LIMIT/OFFSET window (as ActiveRecord's
  # `find_nth_with_limit` does): `limit(3).first(10)` returns three rows and
  # `limit(1).second` returns `nil`.
  private def first_records_from(index : Int32, count : Int32) : Array(Model)
    effective = count.to_i64
    if window = @limit
      effective = Math.min(window - index, effective)
    end
    return [] of Model if effective <= 0

    copy = ordered_copy
    copy.offset!((@offset || 0_i64) + index) unless index.zero?
    copy.limit!(effective).select
  end

  # The SQL `first` runs for this relation: the ordered statement with
  # `LIMIT 1`. `Model.find` keeps it per model (`Grant::PrimaryKeyLookup`).
  #
  # :nodoc:
  def __first_statement_sql : String
    copy = ordered_copy
    copy.limit!(1)
    copy.assembler.select.raw_sql
  end

  private def limit_or_offset? : Bool
    !@limit.nil? || !@offset.nil?
  end

  # Returns a copy ordered for `first`/`last`/ordinal finders: the relation's
  # own `ORDER BY` when it has one (flipped for *reverse*), otherwise the
  # implicit order. The receiver is never changed.
  private def ordered_copy(reverse : Bool = false) : self
    copy = chain_copy
    copy.apply_ordered_finder_order(reverse)
    copy
  end

  # :nodoc:
  protected def apply_ordered_finder_order(reverse : Bool) : Nil
    if @order_fields.empty?
      direction = reverse ? Sort::Descending : Sort::Ascending
      implicit_order_columns.each do |column|
        own_order_fields << {field: column, direction: direction}
      end
    elsif reverse
      reverse_order!
    end
  end

  # Columns that order an otherwise unordered relation for `first`, `last`,
  # the ordinal finders and `find_each`: the model's `implicit_order_column`s
  # followed by its primary key column(s), without repeats.
  def implicit_order_columns : Array(String)
    columns = Model.implicit_order_columns.dup
    key_columns.each { |column| columns << column unless columns.includes?(column) }
    columns
  end

  private def key_columns : Array(String)
    {% if Model.class.has_method?(:composite_primary_key_columns) %}
      composite = Model.composite_primary_key_columns.map(&.to_s)
      return composite unless composite.empty?
    {% end %}

    [Model.primary_name]
  end

  # Returns how many rows (at most *limit*) the relation matches, using a
  # `SELECT <key> ... LIMIT n` probe on a copy. No rows are hydrated and the
  # receiver keeps its own limit and offset.
  private def probe_row_count(limit : Int32) : Int32
    return 0 if is_none?

    if memoized = @records
      return Math.min(memoized.size, limit)
    end

    probe = chain_copy
    probe.clear_order_fields
    probe_limit = (@limit || limit.to_i64)
    probe.limit!(Math.min(probe_limit, limit.to_i64))
    probe.ids.size
  end

  # Returns `true` when the relation matches no rows. Runs `LIMIT 1` unless
  # the relation is loaded.
  #
  # ```
  # User.where(active: true).empty? # => true/false, without loading rows
  # ```
  def empty? : Bool
    probe_row_count(1) == 0
  end

  # Returns `true` if the relation matches at least one record. Same query as
  # `empty?` (`LIMIT 1`); a `none` relation is always `false`. With a block it
  # falls back to `Enumerable#any?`.
  #
  # ```
  # User.where(active: true).any? # => true/false
  # ```
  def any? : Bool
    probe_row_count(1) > 0
  end

  # Returns `true` if the relation matches no records. Opposite of `any?`.
  def none? : Bool
    empty?
  end

  # Returns `true` if the relation matches more than one record (`LIMIT 2`).
  def many? : Bool
    probe_row_count(2) > 1
  end

  # :ditto:
  def many?(& : Model -> Bool) : Bool
    records.count { |record| yield record } > 1
  end

  # Returns `true` if the relation matches exactly one record (`LIMIT 2`).
  def one? : Bool
    probe_row_count(2) == 1
  end

  # Returns the one record matching the query, asserting uniqueness.
  #
  # Raises `Grant::Querying::NotFound` if there are zero matches, and
  # `Grant::Querying::NotUnique` if there is more than one. Runs `LIMIT 2` on a
  # copy, so it never loads more than two rows and never changes the receiver.
  #
  # ```
  # User.where(email: "a@example.com").sole # => #<User ...> or raises
  # ```
  def sole : Model
    results = if memoized = @records
                memoized
              else
                chain_copy.limit!(2).select
              end

    if results.size == 0
      raise Grant::Querying::NotFound.new("No record found")
    elsif results.size == 1
      results.first
    else
      raise Grant::Querying::NotUnique.new("Multiple records found (expected exactly one)")
    end
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
    return DB::ExecResult.new(0_i64, 0_i64) if is_none?

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
  def touch_all(*fields, time : Time = Grant::Timestamps.current_time) : Int64
    return 0_i64 if is_none?

    Model.guard_writes!
    Model.mark_write_operation
    assembler.touch_all(fields, time: time)
  end

  # Executes a `COUNT(*)` for the current conditions and returns the row count.
  #
  # Counts in the database (no rows are hydrated). A `none` relation returns `0`.
  # Ungrouped results are `Int64`; grouped results map each group key to `Int64`.
  # Routes through IN-list chunking and the index-hint fallback like `select`.
  #
  # ```
  # User.where(active: true).count # => 42
  # ```
  def count : CountResult
    count_without_routing
  end

  protected def count_without_routing : CountResult
    if group_fields.any?
      return empty_group_count if is_none?

      grouped = if should_chunk_in?
                  chunked_grouped_count
                else
                  with_index_hint_fallback(&.grouped_count_single)
                end
      return shape_group_count(grouped)
    end

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

  protected def grouped_count_single : Hash(Array(Grant::Columns::Type), Int64)
    assembler.grouped_count.run
  end

  private def chunked_grouped_count : Hash(Array(Grant::Columns::Type), Int64)
    if @limit || @offset || @having_clauses.any? || @distinct
      raise ArgumentError.new("Grouped counts with chunked IN lists cannot preserve limit, offset, having, or distinct")
    end

    results = {} of Array(Grant::Columns::Type) => Int64
    each_in_chunk do |chunk_query|
      chunk_query.grouped_count_single.each do |key, count|
        results[key] = results.fetch(key, 0_i64) + count
      end
    end
    results
  end

  private def shape_group_count(results : Hash(Array(Grant::Columns::Type), Int64)) : CountResult
    if group_fields.size == 1
      counts = {} of Grant::Columns::Type => Int64
      results.each { |key, count| counts[key.first] = count }
      counts
    else
      results
    end
  end

  private def empty_group_count : CountResult
    if group_fields.size == 1
      {} of Grant::Columns::Type => Int64
    else
      {} of Array(Grant::Columns::Type) => Int64
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
  # Returns an `Int64`, summing grouped counts when the relation is grouped.
  #
  # ```
  # User.where(active: true).size # => 42
  # ```
  def size : Int64
    if memoized = @records
      return memoized.size.to_i64
    end

    result = count
    if result.is_a?(Int64)
      result
    else
      result.values.sum
    end
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
    records.each do |record|
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

  # Marks *associations* to be loaded with the query, avoiding N+1 queries. Returns `self`.
  #
  # `includes` uses one extra query per association level (like `preload`),
  # and switches to a JOIN (like `eager_load`) when a `where` names the
  # included association's table. Records are loaded when the query executes
  # (`select`/`first`/iteration). An unknown association name raises
  # `Grant::AssociationNotFoundError` at that point.
  #
  # Accepts names, arrays, and nested hashes to any depth:
  #
  # ```
  # User.where(active: true).includes(:posts).each do |user|
  #   user.posts # already loaded, no extra query per user
  # end
  # User.all.includes(posts: {comments: :author}, profile: [:avatar])
  # ```
  def includes!(*associations, **nested_associations) : self
    add_association_specs(own_includes_associations, associations, nested_associations)
    self
  end

  # Loads *associations* via separate queries (one per association level). Returns `self`.
  #
  # Like `includes` but never switches to a JOIN, which avoids row
  # multiplication for has_many associations. Takes the same nested forms.
  #
  # ```
  # User.where(active: true).preload(:posts)
  # User.all.preload(posts: :comments)
  # ```
  def preload!(*associations, **nested_associations) : self
    add_association_specs(own_preload_associations, associations, nested_associations)
    self
  end

  # Loads *associations* with a single JOIN against the main query, so the
  # query can filter or order on the joined table, and the loaded association
  # holds only the rows the `where` allows (as in ActiveRecord). Takes the same
  # nested forms as `includes`. Raises `ArgumentError` for a polymorphic
  # `belongs_to` (which has no single table to join).
  #
  # ```
  # User.where(active: true).eager_load(:posts)
  # ```
  def eager_load!(*associations, **nested_associations) : self
    specs = [] of Grant::Includes
    associations.each { |spec| specs.concat(Grant::AssociationLoader.normalize(spec)) }
    specs.concat(Grant::AssociationLoader.normalize(nested_associations)) unless nested_associations.empty?
    Grant::AssociationLoader.enable(Model)
    own_eager_load_associations.concat(specs)
    joins_before = @join_clauses
    was_distinct = @distinct
    specs.each do |spec|
      case spec
      when Symbol then add_eager_load_join(spec)
      when Hash   then spec.each_key { |name| add_eager_load_join(name) }
      end
    end
    # Remember what this call added, so `unscope(:eager_load)` can take it back.
    record_eager_load_joins(@join_clauses - joins_before, !was_distinct && @distinct)
    self
  end

  private def add_association_specs(target : Array(Grant::Includes), positional : Tuple, nested : NamedTuple) : Nil
    Grant::AssociationLoader.enable(Model)
    positional.each { |spec| target.concat(Grant::AssociationLoader.normalize(spec)) }
    target.concat(Grant::AssociationLoader.normalize(nested)) unless nested.empty?
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
  # Returns a new relation; the receiver is unchanged. The block may return
  # the relation it built (`q.where(...)`); a block that only mutates its
  # argument in place through bang methods is honored too.
  def or(& : self ->) : self
    chain_copy.or! { |q| yield q }
  end

  def or!(& : self ->) : self
    reset_load_state
    or_builder = self.class.new(@db_type, :or)
    built = yield or_builder
    or_builder = built if built.is_a?(Builder(Model))

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

      own_where_fields << {
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
  # Returns a new relation; the receiver is unchanged. See `or`.
  def not(& : self ->) : self
    chain_copy.not! { |q| yield q }
  end

  def not!(& : self ->) : self
    reset_load_state
    not_builder = self.class.new(@db_type)
    built = yield not_builder
    not_builder = built if built.is_a?(Builder(Model))

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

      own_where_fields << {
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
    return 0_i64 if is_none?

    Model.guard_writes!

    if should_chunk_in? && (@limit || @offset)
      raise ArgumentError.new("Bulk writes with a chunked IN list cannot preserve limit or offset")
    end

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
  # Combines WHERE conditions with AND, except that an equality (or `IN`) on a
  # column the merged query also constrains replaces the receiver's conditions
  # on that column, like ActiveRecord (last wins). Takes the merged query's
  # ORDER BY, LIMIT, and OFFSET if they are set.
  #
  # Example:
  # ```
  # active = User.where(active: true)
  # admins = User.where(role: "admin")
  # active_admins = active.merge(admins)
  # # WHERE active = true AND role = 'admin'
  #
  # User.where(role: "user").merge(User.where(role: "admin"))
  # # WHERE role = 'admin'
  # ```
  def merge!(other : self) : self
    reset_load_state
    # Clauses the other relation unscoped are removed first, then its own
    # conditions are added back.
    merge_unscopes!(other)
    # Merge where conditions: an equality on a column the other relation also
    # constrains is replaced, not ANDed (see `merge_where_fields!`).
    merge_where_fields!(other)

    # Merge order fields: the other relation's terms are appended (like
    # ActiveRecord), or replace ours when it was built with `reorder`.
    merge_order!(other)

    # Merge group fields
    other.group_fields.each do |field|
      own_group_fields << field unless @group_fields.includes?(field)
    end

    # Merge the column projection
    if other_columns = other.select_columns
      current_columns = @select_columns
      @select_columns = current_columns ? (current_columns + other_columns).uniq : other_columns.dup
    end

    # Use other's limit/offset if set
    @limit = other.limit if other.limit
    @offset = other.offset if other.offset

    # Merge associations
    own_eager_load_associations.concat(other.eager_load_associations).uniq!
    own_preload_associations.concat(other.preload_associations).uniq!
    own_includes_associations.concat(other.includes_associations).uniq!
    @strict_loading = true if other.strict_loading?

    # Use other's lock if set
    take_lock_from!(other)

    # Merge join clauses
    other.join_clauses.each do |jc|
      own_join_clauses << jc unless @join_clauses.includes?(jc)
    end

    # Merge distinct flag
    @distinct = true if other.distinct?

    # Merge having clauses
    other.having_clauses.each do |hc|
      own_having_clauses << hc
    end

    # Merge none flag
    @is_none = true if other.is_none?

    @readonly = true if other.readonly?
    @optimizer_hints = @optimizer_hints | other.optimizer_hint_list
    merge_from_and_with!(other)

    self
  end

  private def and_subquery(field : String, subquery : Builder, join : Symbol = :and)
    safe_field = structured_field_sql(field)
    subquery_assembler = subquery.assembler
    sql = subquery_assembler.select.raw_sql
    values = subquery_assembler.numbered_parameters
    if values.empty?
      own_where_fields << {join: join, stmt: "#{safe_field} IN (#{sql})", value: nil.as(Grant::Columns::Type)}
    else
      own_where_fields << {join: join, stmt: "#{safe_field} IN (#{sql})", values: values}
    end
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
  def select!(*columns : Symbol) : self
    reset_load_state
    @select_columns = columns.map { |column| resolve_column_alias(column.to_s) }.to_a
    self
  end

  # Public chain methods. Each `name!` above mutates the receiver; the method
  # generated here has the same signature, runs `name!` on a copy-on-write copy
  # and returns that copy, so the receiver is never changed (like
  # ActiveRecord's `Relation`). Use the bang forms only on a relation you own,
  # for instance one you just built in a loop.
  {% begin %}
  {% chain = %w(where and or and_in or_in order group_by lock joins left_joins distinct having none reorder reverse_order rewhere reselect regroup unscope offset limit merge includes preload eager_load select) %}
  {% for m in @type.methods %}
    {% n = m.name.stringify %}
    {% if n.ends_with?("!") && chain.includes?(n[0...-1]) && !m.accepts_block? && m.visibility == :public %}
      # :nodoc:
      def {{n[0...-1].id}}({% for arg, i in m.args %}{% if m.splat_index == i %}*{% end %}{% if arg.name.stringify.size > 0 %}{{arg.name}}{% if arg.restriction %} : {{arg.restriction}}{% end %}{% unless arg.default_value.is_a?(Nop) %} = {{arg.default_value}}{% end %}{% end %}, {% end %}{% if m.double_splat %}**{{m.double_splat.name}}, {% end %}) : self
        chain_copy.{{n.id}}({% for arg, i in m.args %}{% if arg.name.stringify.size > 0 %}{% if m.splat_index && i > m.splat_index %}{{arg.name}}: {{arg.name}}{% elsif m.splat_index == i %}*{{arg.name}}{% else %}{{arg.name}}{% end %}, {% end %}{% end %}{% if m.double_splat %}**{{m.double_splat.name}}{% end %})
      end
    {% end %}
  {% end %}
  {% end %}
end

require "./where_composition"
require "./sql_expression"
require "./ordering"
require "./joins"
require "./grouping"
require "./readonly"
require "./locking"
require "./select_expressions"
require "./aggregations"
require "./pluck"
require "./extract_associated"
require "./typed_predicates"
require "./relation_merging"
require "./relation_rewrites"
