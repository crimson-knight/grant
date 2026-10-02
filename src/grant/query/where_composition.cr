require "./builder"

# Resolves which columns a joined table can be queried on. `where(posts:
# {published: true})` and qualified fields (`"posts.published"`) check the
# column against the model behind the table when the association registry
# knows one.
module Grant::Query::JoinedColumns
  # True or false when *qualifier* (an association name or a table name) maps
  # to a model declared as an association of *owner_name*; nil when the
  # registry knows no model for it (a raw joined table).
  def self.known_column?(owner_name : String, qualifier : String, column : String) : Bool?
    Grant::AssociationRegistry.reflections_for(owner_name).each do |reflection|
      next if reflection.polymorphic?
      if reflection.name == qualifier || reflection.klass.table_name == qualifier
        return reflection.klass.fields.includes?(column)
      end
    end

    nil
  end

  # The table name behind *qualifier* (an association name or a table name),
  # or nil when no association of *owner_name* points at it.
  def self.table_for(owner_name : String, qualifier : String) : String?
    Grant::AssociationRegistry.reflections_for(owner_name).each do |reflection|
      next if reflection.polymorphic?
      if reflection.name == qualifier || reflection.klass.table_name == qualifier
        return reflection.klass.table_name
      end
    end

    nil
  end
end

# Where-clause composition: value-shaped conditions (ranges, nested table
# hashes, association records), relation `or`/`and`, `invert_where`,
# `excluding`, `where.associated`/`missing`, named binds and the column-level
# `unscope`/`rewhere`. Kept apart from `builder.cr`; the bang methods mutate
# the receiver and the plain ones run them on a copy-on-write copy.
class Grant::Query::Builder(Model)
  alias FieldClause = NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)

  # Raw WHERE statements this relation generated for a single column (a
  # nil-aware `IN`, an array holding ranges, a record list under an
  # association), keyed by their SQL text and mapped to that column, so
  # `rewhere`, `merge` and `unscope(where:)` remove them with the column's
  # structured conditions. The flag is true for a plain `IN` list, which
  # `merge` treats like an equality. A chain copy gets its own copy of the
  # map (`forget_copied_state`); nothing is shared between relations.
  @raw_where_columns : Hash(String, Tuple(String, Bool))? = nil

  # Records that the raw *stmt* constrains *field* only; *equality* marks a
  # plain `IN` list.
  protected def register_raw_where_column(stmt : String, field : String, equality : Bool = false) : Nil
    raw_columns = @raw_where_columns ||= {} of String => Tuple(String, Bool)
    raw_columns[stmt] = {where_column_key(field), equality}
  end

  # The column a raw clause was registered for and whether it is a plain `IN`
  # list; nil for a user-written or multi-column statement.
  protected def raw_where_column(stmt : String) : Tuple(String, Bool)?
    if raw_columns = @raw_where_columns
      raw_columns[stmt]?
    end
  end

  # Column a WHERE clause constrains when it is tied to exactly one column:
  # a structured field clause, or a raw clause registered for one column.
  private def where_clause_column(clause : WhereField) : String?
    if clause.is_a?(FieldClause)
      where_column_key(clause[:field])
    elsif registered = raw_where_column(clause[:stmt])
      registered[0]
    end
  end

  # Adds one `field => value` condition joined by *join* (`:and` or `:or`).
  # Shared by `where`, `and` and `or`, so every value shape behaves the same
  # in all three. A column named through `alias_attribute` is resolved to the
  # real column first.
  private def add_condition(join : Symbol, field : String, value) : Nil
    if value.is_a?(NamedTuple) || value.is_a?(Hash)
      return add_nested_conditions(join, field, value)
    end
    return add_association_condition(join, field, value) if association_condition?(field)
    {% if Model.class.has_method?(:composite_primary_key_columns) %}
      return add_composite_key_tuple_condition(join, field, value) if value.is_a?(Tuple)
    {% end %}

    field = resolve_column_alias(field)
    {% if Model.class.has_method?(:coerce_where_value) %}
      value = Model.coerce_where_value(field, value)
    {% end %}
    if value.is_a?(Array)
      add_array_condition_per_type(join, field, value)
    elsif value.is_a?(Enum)
      add_field_condition(join, field, :eq, value.to_s)
    elsif value.is_a?(Symbol)
      add_field_condition(join, field, :eq, value.to_s)
    elsif value.is_a?(Range)
      add_range_condition(join, field, value)
    elsif value.is_a?(Builder)
      and_subquery(field: field, subquery: value, join: join)
    elsif value.is_a?(Grant::Base)
      raise ArgumentError.new("#{field.inspect} is not an association of #{Model.name}; a #{value.class.name} record cannot be compared with a column")
    else
      add_field_condition(join, field, :eq, value)
    end
  end

  # A value typed as a union of array types (a `Grant::Columns::Type` from an
  # attributes hash) cannot bind `Array(T)` in `add_array_condition`. When no
  # member holds records or ranges it is a plain `IN` list, as before; any
  # other union is handed over one member type at a time.
  private def add_array_condition_per_type(join : Symbol, field : String, values : V) : Nil forall V
    {% if V.union? %}
      {% plain = V.union_types.all? { |type| !type.type_vars.first.union_types.any? { |element| element <= Range || element <= Grant::Base } } %}
      {% if plain %}
        if join == :or
          or_array(field, :in, values)
        else
          and_array(field, :in, values)
        end
      {% else %}
        {% for type in V.union_types %}
          return add_array_condition(join, field, values) if values.is_a?({{ type }})
        {% end %}
      {% end %}
    {% else %}
      add_array_condition(join, field, values)
    {% end %}
  end

  # An array under a column becomes `IN`. An array of records only makes sense
  # under an association name, which `add_condition` routes elsewhere. Ranges
  # inside the array are ORed in as spans (`[1, 5..9]`).
  private def add_array_condition(join : Symbol, field : String, values : Array(T)) : Nil forall T
    {% if T.union_types.all? { |type| type <= Array || type <= Tuple } %}
      add_composite_key_tuples_condition(join, field, values)
    {% elsif T.union_types.any? { |type| type <= Grant::Base } %}
      raise ArgumentError.new("#{field.inspect} is not an association of #{Model.name}; records cannot be compared with a column")
    {% elsif T.union_types.any? { |type| type <= Range } %}
      add_mixed_array_condition(join, field, values)
    {% else %}
      if join == :or
        or_array(field, :in, values)
      else
        and_array(field, :in, values)
      end
    {% end %}
  end

  # `field IN (...) OR field IS NULL OR (field >= ? AND field <= ?)` for an
  # array that mixes plain values, nil and ranges.
  private def add_mixed_array_condition(join : Symbol, field : String, values : Array) : Nil
    field_sql = structured_field_sql(field)
    scalars = [] of Grant::Columns::Type
    spans = [] of String
    span_values = [] of Grant::Columns::Type
    has_nil = false

    values.each do |item|
      if item.is_a?(Range)
        predicate, bound_values = range_predicate(field_sql, item)
        spans << predicate
        span_values.concat(bound_values)
      elsif item.nil?
        has_nil = true
      else
        scalars << item.as(Grant::Columns::Type)
      end
    end

    parts = [] of String
    parts << (scalars.size == 1 ? "#{field_sql} = ?" : "#{field_sql} IN (#{Array.new(scalars.size, "?").join(", ")})") unless scalars.empty?
    parts << "#{field_sql} IS NULL" if has_nil
    parts.concat(spans)

    bound = scalars + span_values
    predicate = parts.empty? ? "1=0" : "(#{parts.join(" OR ")})"
    own_where_fields << {join: join, stmt: predicate, values: bound}
    register_raw_where_column(predicate, field) unless parts.empty?
  end

  # SQL for one range over an already-quoted column: the bounds it has, ANDed
  # (`1=1` when it has neither), with their values.
  private def range_predicate(field_sql : String, range : Range) : Tuple(String, Array(Grant::Columns::Type))
    parts = [] of String
    values = [] of Grant::Columns::Type
    if lower = range.begin
      parts << "#{field_sql} >= ?"
      values << lower.as(Grant::Columns::Type)
    end
    if upper = range.end
      parts << "#{field_sql} #{range.exclusive? ? "<" : "<="} ?"
      values << upper.as(Grant::Columns::Type)
    end
    {parts.empty? ? "1=1" : "(#{parts.join(" AND ")})", values}
  end

  private def add_field_condition(join : Symbol, field : String, operator : Symbol, value : Grant::Columns::Type) : Nil
    own_where_fields << {join: join, field: field, operator: operator, value: value}
  end

  # A range becomes `>=` and `<=` (or `<` for an exclusive end). A beginless
  # or endless range keeps only its one bound; a range with neither bound
  # constrains nothing.
  private def add_range_condition(join : Symbol, field : String, range : Range) : Nil
    upper_operator = range.exclusive? ? :lt : :lteq

    if join == :and
      if lower = range.begin
        add_field_condition(:and, field, :gteq, lower)
      end
      if upper = range.end
        add_field_condition(:and, field, upper_operator, upper)
      end
      return
    end

    predicate, values = range_predicate(structured_field_sql(field), range)
    own_where_fields << {join: :or, stmt: predicate, values: values}
    register_raw_where_column(predicate, field) unless values.empty?
  end

  # `where(posts: {published: true})`: conditions on a joined table. The table
  # must be the model's own or one of its associations (by association or table
  # name), so the qualifier is always a known identifier.
  private def add_nested_conditions(join : Symbol, table_key : String, conditions) : Nil
    # `where(settings: {theme: "dark"})` on a JSON column is containment.
    return add_json_condition(join, table_key, conditions) if json_document_column?(table_key)

    qualifier = if table_key == Model.table_name
                  table_key
                else
                  Grant::Query::JoinedColumns.table_for(Model.name, table_key) ||
                    raise ArgumentError.new("Unknown table #{table_key.inspect} for #{Model.name}; it is not an association or associated table")
                end

    conditions.each do |column, value|
      add_condition(join, "#{qualifier}.#{column}", value)
    end
  end

  # True when *field* is not a column but names a `belongs_to` association.
  private def association_condition?(field : String) : Bool
    return false if Model.fields.includes?(field)

    if reflection = Grant::AssociationRegistry.reflection(Model.name, field)
      reflection.belongs_to?
    else
      false
    end
  end

  # `where(author: user)`, `where(author: [a, b])`, `where(author: nil)`: the
  # foreign key (plus the type column of a polymorphic association) of the
  # given records. Only the key of each record is read; nothing is loaded.
  private def add_association_condition(join : Symbol, name : String, value) : Nil
    reflection = Grant::AssociationRegistry.reflection(Model.name, name) || raise Grant::AssociationNotFoundError.new(Model.name, name)
    entries = association_key_entries(value)
    foreign_key = reflection.foreign_key

    if entries.empty?
      own_where_fields << {join: join, stmt: "1=0", value: nil.as(Grant::Columns::Type)}
      return
    end

    unless reflection.polymorphic?
      if entries.size == 1
        add_field_condition(join, foreign_key, :eq, entries.first[0])
      else
        keys = entries.map(&.[0])
        predicate, values = key_list_predicate(structured_field_sql(foreign_key), keys)
        own_where_fields << {join: join, stmt: predicate, values: values}
        register_raw_where_column(predicate, foreign_key, equality: keys.none?(&.nil?))
      end
      return
    end

    type_column = reflection.foreign_type || raise ArgumentError.new("Polymorphic association #{Model.name}##{name} has no type column")
    if join == :and && entries.size == 1 && (type_name = entries.first[1]) && !entries.first[0].nil?
      add_field_condition(:and, foreign_key, :eq, entries.first[0])
      add_field_condition(:and, type_column, :eq, type_name)
      return
    end

    key_sql = structured_field_sql(foreign_key)
    type_sql = structured_field_sql(type_column)
    by_type = {} of String => Array(Grant::Columns::Type)
    null_key = false
    entries.each do |key, type_name|
      if type_name
        (by_type[type_name] ||= [] of Grant::Columns::Type) << key
      elsif key.nil?
        null_key = true
      else
        raise ArgumentError.new("#{Model.name}##{name} is polymorphic; pass records so the type column can be matched")
      end
    end

    parts = [] of String
    values = [] of Grant::Columns::Type
    by_type.each do |type_name, keys|
      predicate, key_values = key_list_predicate(key_sql, keys)
      parts << "(#{predicate} AND #{type_sql} = ?)"
      values.concat(key_values)
      values << type_name
    end
    parts << "#{key_sql} IS NULL" if null_key
    predicate = "(#{parts.join(" OR ")})"
    own_where_fields << {join: join, stmt: predicate, values: values}
    register_raw_where_column(predicate, foreign_key)
  end

  # Foreign key and polymorphic type name for each value passed under an
  # association name: a record contributes its primary key and class name, a
  # scalar or nil is taken as the key itself.
  private def association_key_entries(value) : Array(Tuple(Grant::Columns::Type, String?))
    entries = [] of Tuple(Grant::Columns::Type, String?)
    if value.is_a?(Array)
      value.each { |item| entries.concat(association_key_entries(item)) }
    elsif value.is_a?(Grant::Base)
      key_name = value.class.primary_name || raise ArgumentError.new("#{value.class.name} has no primary key to match an association against")
      entries << {value.read_attribute(key_name).as(Grant::Columns::Type), value.class.polymorphic_name}
    elsif value.is_a?(Grant::Columns::Type)
      entries << {value, nil.as(String?)}
    else
      raise ArgumentError.new("Cannot compare an association with a #{value.class.name}")
    end
    entries
  end

  # `field IN (?, ?)` for *keys*; a nil key also matches NULL, an empty list
  # matches nothing.
  private def key_list_predicate(field_sql : String, keys : Array(Grant::Columns::Type)) : Tuple(String, Array(Grant::Columns::Type))
    present = keys.reject(&.nil?)
    has_nil = present.size != keys.size
    return {has_nil ? "#{field_sql} IS NULL" : "1=0", [] of Grant::Columns::Type} if present.empty?

    placeholders = Array.new(present.size, "?").join(", ")
    predicate = present.size == 1 ? "#{field_sql} = ?" : "#{field_sql} IN (#{placeholders})"
    predicate = "(#{predicate} OR #{field_sql} IS NULL)" if has_nil
    {predicate, present}
  end

  # ---- named binds ---------------------------------------------------------

  # Adds a raw condition with named binds: `where("age > :min", min: 18)`.
  # A list value expands to one placeholder per element (`IN (:ids)`); `::`
  # casts and text inside quotes or comments are left alone.
  def where!(stmt : String, **binds) : self
    return and!(stmt) if binds.empty?

    rewritten, values = Grant::Sanitization.rewrite_named_binds(stmt, binds)
    values.empty? ? and!(rewritten) : and!(rewritten, values)
  end

  def where(stmt : String, **binds) : self
    chain_copy.where!(stmt, **binds)
  end

  # ---- where.not, invert_where ----------------------------------------------

  # A relation over the same tables and joins with no WHERE conditions, used to
  # build a group of conditions before they are folded into one clause.
  private def blank_where_scope : self
    scope = chain_copy
    scope.clear_where_fields
    scope.clear_default_scope_where_fields
    scope
  end

  # Wraps the conditions in *matches* in one `NOT (...)`, so several keys are
  # a NAND (`NOT (a = 1 AND b = 2)`). Values follow `where`: arrays become
  # `NOT IN`, nil `IS NOT NULL`, ranges a negated span.
  def where_not!(matches) : self
    scope = blank_where_scope
    scope.where!(matches)
    append_where_group(scope, negated: true)
  end

  def where_not(matches) : self
    chain_copy.where_not!(matches)
  end

  # Folds *source*'s WHERE conditions into one `(...)` or `NOT (...)` clause
  # ANDed onto this relation, keeping the bind values in order.
  private def append_where_group(source : Builder(Model), negated : Bool = false) : self
    return self if source.where_fields.empty?

    collapse_or_fields!
    assembler_for_group = assembler
    sql = assembler_for_group.where_group_sql(source.where_fields)
    own_where_fields << {join: :and, stmt: "#{negated ? "NOT " : ""}(#{sql})", values: assembler_for_group.numbered_parameters}
    self
  end

  # Replaces mixed AND/OR conditions with one parenthesized clause, so a
  # condition ANDed afterwards cannot split them by operator precedence.
  private def collapse_or_fields! : Nil
    return if @where_fields.size < 2 || @where_fields.none? { |clause| clause[:join] == :or }

    group_assembler = assembler
    sql = group_assembler.where_group_sql(@where_fields)
    values = group_assembler.numbered_parameters
    clear_where_fields
    own_where_fields << {join: :and, stmt: "(#{sql})", values: values}
  end

  # Negates every WHERE condition accumulated so far into a single
  # `NOT (a AND b)`. Default-scope conditions stay outside the negation.
  # NULL follows SQL's three-valued logic, as in ActiveRecord: a row whose
  # column is NULL matches neither `col = 1` nor its inversion.
  #
  # ```
  # User.where(active: true, role: "admin").invert_where
  # # => WHERE NOT (active = true AND role = 'admin')
  # ```
  def invert_where! : self
    return self if @where_fields.empty?

    group_assembler = assembler
    sql = group_assembler.where_group_sql(@where_fields)
    values = group_assembler.numbered_parameters
    clear_where_fields
    own_where_fields << {join: :and, stmt: "NOT (#{sql})", values: values}
    self
  end

  def invert_where : self
    chain_copy.invert_where!
  end

  # ---- relation or / and -------------------------------------------------------

  # ORs this relation's conditions with *other*'s: `WHERE (a) OR (b)`. Both
  # relations must agree on everything but WHERE and HAVING (ordering, joins,
  # limit, ...), or `ArgumentError` names the values that differ. When either
  # side has no conditions the result has none, as in ActiveRecord.
  #
  # ```
  # User.where(role: "admin").or(User.where(active: true))
  # # => WHERE (role = 'admin') OR (active = true)
  # ```
  def or!(other : Builder(Model)) : self
    ensure_structurally_compatible!(other, "or")

    if @where_fields.empty? || other.where_fields.empty?
      clear_where_fields
      return self
    end

    group_assembler = assembler
    left = group_assembler.where_group_sql(@where_fields)
    right = group_assembler.where_group_sql(other.where_fields)
    values = group_assembler.numbered_parameters
    clear_where_fields
    own_where_fields << {join: :and, stmt: "((#{left}) OR (#{right}))", values: values}
    self
  end

  def or(other : Builder(Model)) : self
    chain_copy.or!(other)
  end

  # ANDs *other*'s conditions onto this relation. Same compatibility rule as
  # `or`. Conditions on the same column are kept (use `merge` to replace them).
  def and!(other : Builder(Model)) : self
    ensure_structurally_compatible!(other, "and")
    return self if other.where_fields.empty?

    if other.where_fields.all? { |clause| clause[:join] == :and }
      collapse_or_fields!
      own_where_fields.concat(other.where_fields)
      adopt_raw_where_columns(other, other.where_fields)
      self
    else
      append_where_group(other)
    end
  end

  def and(other : Builder(Model)) : self
    chain_copy.and!(other)
  end

  # Names of the relation components on which this relation and *other* differ.
  protected def structurally_incompatible_values(other : Builder(Model)) : Array(Symbol)
    differing = [] of Symbol
    differing << :order if @order_fields != other.order_fields
    differing << :group if @group_fields != other.group_fields
    differing << :joins if @join_clauses != other.join_clauses
    differing << :limit if @limit != other.limit
    differing << :offset if @offset != other.offset
    differing << :lock if @lock_mode != other.lock_mode || @lock_clause != other.lock_clause
    differing << :select if @select_columns != other.select_columns
    differing << :distinct if @distinct != other.distinct?
    differing << :includes if @includes_associations != other.includes_associations
    differing << :preload if @preload_associations != other.preload_associations
    differing << :eager_load if @eager_load_associations != other.eager_load_associations
    differing
  end

  private def ensure_structurally_compatible!(other : Builder(Model), method_name : String) : Nil
    differing = structurally_incompatible_values(other)
    return if differing.empty?

    raise ArgumentError.new("Relation passed to ##{method_name} must be structurally compatible. Incompatible values: #{differing.inspect}")
  end

  # ---- merge ---------------------------------------------------------------------

  # Merges an anonymous relation built by the block: the block receives an
  # empty relation and returns what to merge in.
  #
  # ```
  # User.where(role: "user").merge { |scope| scope.where(role: "admin") }
  # # => WHERE role = 'admin'
  # ```
  def merge!(& : Builder(Model) -> Builder(Model)) : self
    merge!(yield self.class.new(@db_type))
  end

  def merge(& : Builder(Model) -> Builder(Model)) : self
    chain_copy.merge! { |scope| yield scope }
  end

  # Merges keyword conditions the way a merged `where(**matches)` relation
  # would, replacing same-column equalities.
  def merge!(**matches) : self
    scope = self.class.new(@db_type)
    scope.where!(matches)
    merge!(scope)
  end

  def merge(**matches) : self
    chain_copy.merge!(**matches)
  end

  # Merges *other*'s WHERE conditions. An equality or `IN` on a column that
  # *other* also constrains replaces this relation's conditions on that column
  # (last wins); everything else is ANDed. Columns are indexed in a small set
  # while merging, so the cost is linear in the clause count.
  protected def merge_where_fields!(other : Builder(Model)) : Nil
    incoming = other.where_fields
    return if incoming.empty?

    incoming_flat = incoming.all? { |clause| clause[:join] == :and }
    own_flat = @where_fields.all? { |clause| clause[:join] == :and }

    if incoming_flat && own_flat
      replaced = Set(String).new
      incoming.each do |clause|
        if clause.is_a?(FieldClause)
          replaced << where_column_key(clause[:field]) if clause[:operator] == :eq || clause[:operator] == :in
        elsif (registered = other.raw_where_column(clause[:stmt])) && registered[1]
          replaced << registered[0]
        end
      end
      remove_where_columns!(replaced) unless replaced.empty?
      own_where_fields.concat(incoming)
      adopt_raw_where_columns(other, incoming)
    else
      append_where_group(other)
    end
  end

  # Column a condition applies to, without the model's own table qualifier.
  private def where_column_key(field : String) : String
    prefix = "#{Model.table_name}."
    field.starts_with?(prefix) ? field[prefix.size..] : field
  end

  # Drops every condition tied to one of *columns*: structured clauses on it
  # and the raw clauses this relation generated for it.
  private def remove_where_columns!(columns : Set(String)) : Nil
    return unless @where_fields.any? { |clause| where_clause_on?(clause, columns) }

    own_where_fields.reject! { |clause| where_clause_on?(clause, columns) }
  end

  private def where_clause_on?(clause : WhereField, columns : Set(String)) : Bool
    if column = where_clause_column(clause)
      columns.includes?(column)
    else
      false
    end
  end

  # Carries *other*'s column registrations for the raw clauses merged in, so
  # a later rewhere or merge can still replace them.
  private def adopt_raw_where_columns(other : Builder(Model), clauses : Array(WhereField)) : Nil
    clauses.each do |clause|
      next if clause.is_a?(FieldClause)

      stmt = clause[:stmt]
      if registered = other.raw_where_column(stmt)
        (@raw_where_columns ||= {} of String => Tuple(String, Bool))[stmt] = registered
      end
    end
  end

  # ---- unscope / rewhere ---------------------------------------------------------

  # Drops the WHERE conditions on the named columns and keeps the rest. A
  # `belongs_to` name stands for its foreign key (and type column).
  #
  # ```
  # User.where(active: true, role: "admin").unscope(where: :active)
  # # => WHERE role = 'admin'
  # User.where(active: true).order(:id).unscope(:order, where: :active)
  # ```
  def unscope!(*components : Symbol, where columns : Symbol | Array(Symbol)) : self
    record_unscope(components.to_a)
    unscope_components!(components.to_a)
    unscope_where_columns!(where_column_names(columns))
  end

  # :ditto:
  def unscope!(*, where columns : Symbol | Array(Symbol)) : self
    unscope_where_columns!(where_column_names(columns))
  end

  def unscope(*components : Symbol, where columns : Symbol | Array(Symbol)) : self
    chain_copy.unscope!(*components, where: columns)
  end

  # :ditto:
  def unscope(*, where columns : Symbol | Array(Symbol)) : self
    chain_copy.unscope!(where: columns)
  end

  private def where_column_names(columns : Symbol | Array(Symbol)) : Array(String)
    columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
  end

  protected def unscope_where_columns!(names : Array(String)) : self
    record_unscoped_columns(names)
    reset_load_state
    columns = Set(String).new
    names.each { |name| expand_where_column_name(name).each { |column| columns << column } }
    remove_where_columns!(columns)
    self
  end

  private def expand_where_column_name(name : String) : Array(String)
    return [name] if Model.fields.includes?(name)

    reflection = Grant::AssociationRegistry.reflection(Model.name, name)
    return [name] unless reflection && reflection.belongs_to?

    columns = [reflection.foreign_key]
    if type_column = reflection.foreign_type
      columns << type_column
    end
    columns
  end

  # Components `unscope` accepts beyond the ones in `builder.cr`.
  protected def unscope_extra_component!(component : Symbol) : Bool
    case component
    when :includes
      clear_includes_associations
    when :preload
      clear_preload_associations
    when :eager_load
      clear_eager_load_associations
      drop_eager_load_joins!
    else
      return unscope_relation_state!(component)
    end

    true
  end

  # ---- excluding / without ---------------------------------------------------------

  # Excludes the given records: `WHERE id NOT IN (...)`. Records without a
  # primary key value are ignored, and no records means no condition.
  # Composite keys exclude each key combination.
  #
  # ```
  # User.excluding(admin, guest)
  # User.where(active: true).excluding(users)
  # ```
  def excluding!(*records : Model) : self
    excluding!(records.to_a)
  end

  def excluding!(records : Array(Model)) : self
    return self if records.empty?

    columns = key_columns
    if columns.size > 1
      exclude_composite_keys(columns, records)
    else
      ids = records.map(&.primary_key_value)
      and_in!(columns.first, ids, negated: true) unless ids.all?(&.nil?)
    end
    self
  end

  def excluding(*records : Model) : self
    chain_copy.excluding!(records.to_a)
  end

  def excluding(records : Array(Model)) : self
    chain_copy.excluding!(records)
  end

  def without!(*records : Model) : self
    excluding!(records.to_a)
  end

  def without!(records : Array(Model)) : self
    excluding!(records)
  end

  def without(*records : Model) : self
    chain_copy.excluding!(records.to_a)
  end

  def without(records : Array(Model)) : self
    chain_copy.excluding!(records)
  end

  private def exclude_composite_keys(columns : Array(String), records : Array(Model)) : Nil
    alternatives = [] of String
    values = [] of Grant::Columns::Type
    columns_sql = columns.map { |column| structured_field_sql(column) }

    records.each do |record|
      key_values = record.primary_key_values
      next unless columns.all? { |column| !key_values[column]?.nil? }

      alternatives << "(#{columns_sql.map { |sql| "#{sql} = ?" }.join(" AND ")})"
      columns.each { |column| values << key_values[column] }
    end
    return if alternatives.empty?

    own_where_fields << {join: :and, stmt: "NOT (#{alternatives.join(" OR ")})", values: values}
  end

  # ---- where.associated / where.missing --------------------------------------------

  # Keeps only records that have a matching record in each named association:
  # one `EXISTS (...)` subquery per name, so a parent is returned once however
  # many children it has (no duplicate rows, no DISTINCT).
  def where_associated!(names : Array(Symbol)) : self
    names.each { |name| append_association_exists(name.to_s, negated: false) }
    self
  end

  def where_associated(names : Array(Symbol)) : self
    chain_copy.where_associated!(names)
  end

  # Keeps only records that have no matching record in any of the named
  # associations: one `NOT EXISTS (...)` per name.
  def where_missing!(names : Array(Symbol)) : self
    names.each { |name| append_association_exists(name.to_s, negated: true) }
    self
  end

  def where_missing(names : Array(Symbol)) : self
    chain_copy.where_missing!(names)
  end
end

module Grant::Query::BuilderMethods
  def where(stmt : String, **binds)
    __builder.where(stmt, **binds)
  end

  delegate excluding, without, to: __builder
end
