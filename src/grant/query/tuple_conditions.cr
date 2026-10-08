module Grant::Query
  # How a multi-column `IN` over key tuples is written.
  #
  # * `Auto` uses a row-value `IN`: `(a, b) IN ((?, ?), (?, ?))` on PostgreSQL
  #   and MySQL, `(a, b) IN (VALUES (?, ?), (?, ?))` on SQLite (which only
  #   accepts a row value against a subquery). A list holding a NULL part falls
  #   back to OR expansion, because a row value never equals NULL.
  # * `RowValue` always uses the row-value form.
  # * `OrExpansion` writes `(a = ? AND b = ?) OR (a = ? AND b = ?)`; it is
  #   capped at `TupleConditions::OR_EXPANSION_LIMIT` tuples so the statement
  #   cannot balloon.
  enum TupleStrategy
    Auto
    RowValue
    OrExpansion
  end

  # Most tuples an OR-expanded predicate may hold.
  module TupleConditions
    OR_EXPANSION_LIMIT = 200
  end
end

# Tuple predicates: matching rows by several columns at once, which is what
# composite primary keys, `query_constraints` and composite foreign keys need.
class Grant::Query::Builder(Model)
  # ANDs a predicate onto the relation that keeps rows whose *columns* equal one
  # of *tuples* (`negated: true` keeps the rest). One column degrades to a plain
  # `IN`. Every tuple needs one value per column.
  #
  # ```
  # OrderItem.where_tuples([:shop_id, :order_id], [{1_i64, 2_i64}, {1_i64, 3_i64}])
  # # PG/MySQL: WHERE (shop_id, order_id) IN ((1, 2), (1, 3))
  # ```
  #
  # Raises `ArgumentError` for an unknown column, a tuple of the wrong size, or
  # more than `Grant.settings.in_clause_limit` tuples (chunk the list, or use
  # `find_keys` which does).
  def where_tuples!(columns : Array(String), tuples : Array(Array(Grant::Columns::Type)),
                    strategy : Grant::Query::TupleStrategy = :auto, negated : Bool = false) : self
    raise ArgumentError.new("where_tuples needs at least one column") if columns.empty?
    tuples.each do |tuple|
      if tuple.size != columns.size
        raise ArgumentError.new("Key tuple #{tuple.inspect} has #{tuple.size} values for #{columns.size} columns (#{columns.join(", ")})")
      end
    end

    if columns.size == 1
      return and_single_column_in(columns.first, tuples.map(&.first), negated)
    end

    if tuples.size > Grant.settings.in_clause_limit
      raise ArgumentError.new("#{tuples.size} key tuples exceed in_clause_limit (#{Grant.settings.in_clause_limit}); query them in chunks")
    end

    if tuples.empty?
      own_where_fields << {join: :and, stmt: negated ? "1=1" : "1=0", value: nil.as(Grant::Columns::Type)}
      return self
    end

    columns_sql = columns.map { |column| structured_field_sql(column) }
    values = [] of Grant::Columns::Type
    statement = if use_or_expansion?(strategy, tuples)
                  tuple_or_expansion_sql(columns_sql, tuples, values, negated)
                else
                  tuple_row_value_sql(columns_sql, tuples, values, negated)
                end
    own_where_fields << {join: :and, stmt: statement, values: values}
    self
  end

  # :ditto:
  def where_tuples(columns : Array(String), tuples : Array(Array(Grant::Columns::Type)),
                   strategy : Grant::Query::TupleStrategy = :auto, negated : Bool = false) : self
    chain_copy.where_tuples!(columns, tuples, strategy, negated)
  end

  # Typed form: *columns* as symbols or strings (an array or a tuple) and
  # *tuples* as an array of `Tuple`s.
  def where_tuples(columns : Array | Tuple, tuples : Array(Tuple),
                   strategy : Grant::Query::TupleStrategy = :auto, negated : Bool = false) : self
    where_tuples(columns.to_a.map(&.to_s), tuples.map { |tuple| tuple_values(tuple) }, strategy, negated)
  end

  # Keeps only rows that match none of *tuples* (`NOT IN`).
  def where_not_tuples(columns : Array | Tuple, tuples : Array(Tuple),
                       strategy : Grant::Query::TupleStrategy = :auto) : self
    where_tuples(columns, tuples, strategy, negated: true)
  end

  # Keeps the row(s) whose key columns (`Model.persistence_key_columns`: the
  # `query_constraints`, else the composite primary key, else the primary key)
  # equal *key*, given as a `Tuple` in column order.
  def where_key(key : Tuple) : self
    columns = lookup_key_columns
    if key.size != columns.size
      raise ArgumentError.new("#{Model.name} is keyed by #{columns.join(", ")}; got #{key.size} value(s)")
    end
    scope = chain_copy
    columns.each_with_index do |column, index|
      value = key[index].as(Grant::Columns::Type)
      if value.nil?
        scope.where!("#{structured_field_sql(column)} IS NULL")
      else
        scope.where!(column, :eq, value)
      end
    end
    scope
  end

  # :ditto: *key* names every key column, in any order.
  def where_key(key : NamedTuple) : self
    columns = lookup_key_columns
    if key.size != columns.size
      raise ArgumentError.new("#{Model.name} is keyed by #{columns.join(", ")}; got #{key.keys.join(", ")}")
    end
    scope = chain_copy
    columns.each do |column|
      raise ArgumentError.new("Missing key column #{column} for #{Model.name}") unless key.has_key?(column)
      value = key[column].as(Grant::Columns::Type)
      if value.nil?
        scope.where!("#{structured_field_sql(column)} IS NULL")
      else
        scope.where!(column, :eq, value)
      end
    end
    scope
  end

  # Keeps the rows whose key columns equal any of *keys*: one row-value `IN`.
  def where_keys(keys : Array(Tuple), strategy : Grant::Query::TupleStrategy = :auto) : self
    where_tuples(lookup_key_columns, keys, strategy)
  end

  # Returns the rows matching any of *keys* (tuples in key column order), in
  # *keys* order; missing keys are skipped. Lists longer than
  # `Grant.settings.in_clause_limit` run as several queries.
  def find_keys(keys : Array(Tuple)) : Array(Model)
    found_records_by_keys(keys).first
  end

  # Like `find_keys`, raising `Grant::Querying::NotFound` naming every missing key.
  def find_keys!(keys : Array(Tuple)) : Array(Model)
    records, missing = found_records_by_keys(keys)
    unless missing.empty?
      raise Grant::Querying::NotFound.new("Couldn't find all #{Model.name} with '#{lookup_key_columns.join(", ")}': (#{missing.join("), (")}) (found #{records.size} results, but was looking for #{keys.size})")
    end
    records
  end

  # Returns the row with key *key* in this relation, or `nil`.
  def find(key : Tuple) : Model?
    where_key(key).first
  end

  # :ditto:
  def find(key : NamedTuple) : Model?
    where_key(key).first
  end

  # Like `find(key)`, raising `Grant::Querying::NotFound` when there is no row.
  def find!(key : Tuple) : Model
    find(key) || raise Grant::Querying::NotFound.new("Couldn't find #{Model.name} with '#{lookup_key_columns.join(", ")}'=(#{key.to_a.join(", ")})")
  end

  # :ditto:
  def find!(key : NamedTuple) : Model
    find(key) || raise Grant::Querying::NotFound.new("Couldn't find #{Model.name} with #{key}")
  end

  # Columns a key lookup uses: the model's persistence key when it declares one
  # (composite key or `query_constraints`), else its primary key column.
  private def lookup_key_columns : Array(String)
    {% if Model.class.has_method?(:persistence_key_columns) %}
      Model.persistence_key_columns
    {% else %}
      [Model.primary_name]
    {% end %}
  end

  # `where(id: [[shop, id], ...])` or `where(id: {shop, id})` on a model with a
  # composite primary key addresses whole key tuples, as in ActiveRecord.
  # Returns false, adding nothing, for every other condition.
  private def add_composite_key_tuples_condition(join : Symbol, field : String, values : Array) : Nil
    unless join == :and && field == "id" && composite_key_model?
      raise ArgumentError.new("#{field.inspect} cannot be compared with key tuples on #{Model.name}; only where(id: [[a, b], ...]) on a composite primary key is supported")
    end
    where_tuples!(lookup_key_columns, values.map { |element| tuple_values(element) })
  end

  private def add_composite_key_tuple_condition(join : Symbol, field : String, value : Tuple) : Nil
    unless join == :and && field == "id" && composite_key_model?
      raise ArgumentError.new("A tuple value is only accepted for the composite primary key of #{Model.name} (where(id: {a, b}))")
    end
    where_tuples!(lookup_key_columns, [tuple_values(value)])
  end

  # The builder takes homogeneous lists, so a single key column's values are
  # narrowed to their concrete type first (see `AssociationLoader.where_in`).
  private def and_single_column_in(column : String, values : Array(Grant::Columns::Type), negated : Bool) : self
    case values.find { |value| !value.nil? }
    when Int64  then and_in!(column, values.map(&.as(Int64?)), negated)
    when Int32  then and_in!(column, values.map(&.as(Int32?)), negated)
    when Int16  then and_in!(column, values.map(&.as(Int16?)), negated)
    when String then and_in!(column, values.map(&.as(String?)), negated)
    when UUID   then and_in!(column, values.map(&.as(UUID?)), negated)
    when Nil    then and_in!(column, values.map(&.as(Int64?)), negated)
    else
      raise ArgumentError.new("Cannot build a key list from #{values.first.class} values")
    end
  end

  private def composite_key_model? : Bool
    {% if Model.class.has_method?(:composite_primary_key_columns) %}
      Model.composite_primary_key?
    {% else %}
      false
    {% end %}
  end

  private def tuple_values(list : Array) : Array(Grant::Columns::Type)
    values = [] of Grant::Columns::Type
    list.each { |value| values << value.as(Grant::Columns::Type) }
    values
  end

  private def tuple_values(tuple : Tuple) : Array(Grant::Columns::Type)
    values = [] of Grant::Columns::Type
    tuple.each { |value| values << value.as(Grant::Columns::Type) }
    values
  end

  private def found_records_by_keys(keys : Array(Tuple)) : {Array(Model), Array(String)}
    return {[] of Model, [] of String} if keys.empty?

    columns = lookup_key_columns
    wanted = keys.map { |key| tuple_values(key) }
    by_key = {} of String => Model
    chunk_size = Grant.settings.in_clause_limit
    wanted.each_slice(chunk_size) do |chunk|
      chain_copy.where_tuples!(columns, chunk).select.each do |record|
        by_key[tuple_identity(columns.map { |column| record.read_attribute(column) })] = record
      end
    end

    ordered = [] of Model
    missing = [] of String
    wanted.each do |key|
      if record = by_key[tuple_identity(key)]?
        ordered << record
      else
        missing << key.join(", ")
      end
    end
    {ordered, missing}
  end

  # Text identity of a key tuple, so Int32 and Int64 spellings of one key match.
  private def tuple_identity(values : Array(Grant::Columns::Type)) : String
    values.map(&.to_s).join('\u{1f}')
  end

  private def use_or_expansion?(strategy : Grant::Query::TupleStrategy, tuples : Array(Array(Grant::Columns::Type))) : Bool
    case strategy
    in .or_expansion? then true
    in .row_value?    then false
    in .auto?         then tuples.any?(&.any?(Nil))
    end
  end

  private def tuple_row_value_sql(columns_sql : Array(String), tuples : Array(Array(Grant::Columns::Type)),
                                  values : Array(Grant::Columns::Type), negated : Bool) : String
    row = "(#{Array.new(columns_sql.size, "?").join(", ")})"
    rows = Array.new(tuples.size, row).join(", ")
    tuples.each { |tuple| tuple.each { |value| values << value } }
    operator = negated ? "NOT IN" : "IN"
    # SQLite accepts a row value on the left of IN only against a subquery.
    list = @relation_state.db_type.sqlite? ? "VALUES #{rows}" : rows
    "(#{columns_sql.join(", ")}) #{operator} (#{list})"
  end

  private def tuple_or_expansion_sql(columns_sql : Array(String), tuples : Array(Array(Grant::Columns::Type)),
                                     values : Array(Grant::Columns::Type), negated : Bool) : String
    if tuples.size > Grant::Query::TupleConditions::OR_EXPANSION_LIMIT
      raise ArgumentError.new("#{tuples.size} key tuples exceed the OR expansion limit (#{Grant::Query::TupleConditions::OR_EXPANSION_LIMIT}); use the row-value strategy or chunk the list")
    end

    alternatives = tuples.map do |tuple|
      parts = columns_sql.map_with_index do |column_sql, index|
        value = tuple[index]
        if value.nil?
          "#{column_sql} IS NULL"
        else
          values << value
          "#{column_sql} = ?"
        end
      end
      "(#{parts.join(" AND ")})"
    end
    predicate = "(#{alternatives.join(" OR ")})"
    negated ? "NOT #{predicate}" : predicate
  end
end

# Class-level forms: `OrderItem.where_tuples(...)` starts from the model's
# current scope.
module Grant::Query::BuilderMethods
  def where_tuples(columns : Array(String), tuples : Array(Array(Grant::Columns::Type)),
                   strategy : Grant::Query::TupleStrategy = :auto, negated : Bool = false)
    __builder.where_tuples(columns, tuples, strategy, negated)
  end

  def where_tuples(columns : Array | Tuple, tuples : Array(Tuple),
                   strategy : Grant::Query::TupleStrategy = :auto, negated : Bool = false)
    __builder.where_tuples(columns, tuples, strategy, negated)
  end

  def where_not_tuples(columns : Array | Tuple, tuples : Array(Tuple),
                       strategy : Grant::Query::TupleStrategy = :auto)
    __builder.where_not_tuples(columns, tuples, strategy)
  end

  def where_key(key : Tuple | NamedTuple)
    __builder.where_key(key)
  end

  def where_keys(keys : Array(Tuple), strategy : Grant::Query::TupleStrategy = :auto)
    __builder.where_keys(keys, strategy)
  end
end
