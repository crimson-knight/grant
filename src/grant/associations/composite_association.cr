# Runtime support for associations with a composite foreign key (see
# `Grant::Associations.composite_belongs_to`). The macros generate thin methods
# that delegate here, so the loading logic is compiled once per target model
# instead of once per association.
module Grant::CompositeAssociation
  # Loads the target rows whose key columns match a batch of key tuples.
  alias TupleLoader = Proc(Array(Array(Grant::Columns::Type)), Array(Grant::Base))

  # Separates the parts of a key tuple when it is used as a hash key.
  IDENTITY_SEPARATOR = '\u{1f}'

  @@key_columns = {} of String => Proc(Array(String))

  # Records how to read the key columns of the model named *name*; every model
  # that includes `Grant::CompositePrimaryKey` registers itself, so code that
  # only holds a class name (joins) can resolve a blank `primary_key`.
  #
  # :nodoc:
  def self.register_key_columns(name : String, reader : Proc(Array(String))) : Nil
    @@key_columns[name] = reader
  end

  # The key columns of the model named *name*, or nil when it declares no
  # composite key or query constraints.
  def self.key_columns_named(name : String) : Array(String)?
    @@key_columns[name]?.try(&.call)
  end

  # `ON` condition of a join over a composite association: one equality per
  # key column, ANDed. *foreign_key* and *primary_key* are the comma-joined
  # names the association registered; a blank *primary_key* means the parent's
  # own key columns.
  def self.join_on(belongs_to : Bool, owner : Grant::Base.class, target : Grant::Base.class,
                   reference : String, current_table : String, foreign_key : String, primary_key : String) : String
    foreign_columns = foreign_key.split(',')
    parent = belongs_to ? target : owner
    primary_columns = if primary_key.empty?
                        key_columns_named(parent.name) || [parent.primary_name]
                      else
                        primary_key.split(',')
                      end
    ensure_same_size(foreign_columns, primary_columns)
    foreign_columns.map_with_index do |column, index|
      if belongs_to
        "#{reference}.#{primary_columns[index]} = #{current_table}.#{column}"
      else
        "#{reference}.#{column} = #{current_table}.#{primary_columns[index]}"
      end
    end.join(" AND ")
  end

  # The columns that identify a row of *model*: its `query_constraints` or
  # composite primary key, else its primary key.
  def self.key_columns_of(model : M.class) : Array(String) forall M
    {% if M.class.has_method?(:persistence_key_columns) %}
      M.persistence_key_columns
    {% else %}
      [M.primary_name]
    {% end %}
  end

  # The values of *columns* on *record*, or nil when any part is unset (a
  # key with a NULL part references nothing).
  def self.key_values(record : Grant::Base, columns : Array(String)) : Array(Grant::Columns::Type)?
    values = columns.map { |column| record.read_attribute(column) }
    values.any?(&.nil?) ? nil : values
  end

  # :ditto:
  def self.owner_key_values(owner : Grant::Base, columns : Array(String)) : Array(Grant::Columns::Type)?
    key_values(owner, columns)
  end

  # Text identity of a key tuple, so `Int32` and `Int64` spellings of one key
  # match and the tuple can key a `Hash`.
  def self.identity(values : Array(Grant::Columns::Type)) : String
    values.map(&.to_s).join(IDENTITY_SEPARATOR)
  end

  # Whether *foreign_key* is the comma-joined name list a composite
  # association registers.
  def self.composite?(foreign_key : String) : Bool
    foreign_key.includes?(',')
  end

  # Orders *relation* by its model's key columns, so taking the first of
  # several matches is deterministic.
  def self.order_by_key(relation : Grant::Query::Builder(M)) : Nil forall M
    key_columns_of(M).each do |column|
      relation.own_order_fields << {field: column, direction: Grant::Query::Builder::Sort::Ascending}
    end
  end

  # The parent a `belongs_to` with foreign key *foreign_keys* points at.
  def self.find_one(owner : Grant::Base, target : T.class, foreign_keys : Array(String), primary_keys : Array(String),
                    scope : Proc(Grant::Query::Builder(T), Grant::Query::Builder(T))?) : T? forall T
    values = key_values(owner, foreign_keys) || return nil
    relation = T.current_scope
    relation = scope.call(relation) if scope
    relation.where_tuples(primary_keys, [values]).first
  end

  # The child a `has_one` with foreign key *foreign_keys* points back from.
  def self.find_child(owner : Grant::Base, target : T.class, foreign_keys : Array(String), primary_keys : Array(String),
                      scope : Proc(Grant::Query::Builder(T), Grant::Query::Builder(T))?) : T? forall T
    values = key_values(owner, primary_keys) || return nil
    relation = T.current_scope
    relation = scope.call(relation) if scope
    relation.where_tuples(foreign_keys, [values]).first
  end

  # Copies *parent*'s key columns into *record*'s foreign key columns; a nil
  # parent clears them.
  def self.assign_belongs_to(record : Grant::Base, parent : Grant::Base?, foreign_keys : Array(String), primary_keys : Array(String)?) : Nil
    if parent
      keys = primary_keys || raise ArgumentError.new("#{record.class.name}: the referenced key columns are unknown")
      ensure_same_size(foreign_keys, keys)
      foreign_keys.each_with_index do |column, index|
        value = parent.read_attribute(keys[index])
        if value.nil?
          record.clear_nullable_attribute(column)
        else
          record.write_attribute(column, value)
        end
      end
    else
      foreign_keys.each { |column| record.clear_nullable_attribute(column) }
    end
  end

  # Sets *columns* of *record* to *values*.
  def self.assign_key(record : Grant::Base, columns : Array(String), values : Array(Grant::Columns::Type)) : Nil
    ensure_same_size(columns, values)
    columns.each_with_index do |column, index|
      record.write_attribute(column, values[index]) unless record.read_attribute(column) == values[index]
    end
  end

  private def self.ensure_same_size(foreign_keys : Array, referenced : Array) : Nil
    return if foreign_keys.size == referenced.size
    raise ArgumentError.new("A composite foreign key of #{foreign_keys.size} column(s) (#{foreign_keys.join(", ")}) cannot reference #{referenced.size} key column(s)")
  end

  # Batch form of `belongs_to`: one query (per `in_clause_limit` tuples) for
  # every distinct foreign key tuple among *records*.
  def self.preload_belongs_to(records : Array(Grant::Base), name : String, foreign_keys : Array(String),
                              primary_keys : Array(String), loader : TupleLoader) : Nil
    tuples = distinct_tuples(records, foreign_keys)
    lookup = {} of String => Grant::Base
    tuples.each_slice(Grant.settings.in_clause_limit) do |chunk|
      loader.call(chunk).each do |target|
        lookup[identity(primary_keys.map { |column| target.read_attribute(column) })] = target
      end
    end

    inverse = singular_inverse(records, name)
    records.each do |record|
      target = key_values(record, foreign_keys).try { |values| lookup[identity(values)]? }
      record.set_loaded_association(name, target)
      record._adopt_strict_loading(target, false)
      target.set_loaded_association(inverse, record) if target && inverse
    end
  end

  # Batch form of `has_many` (*collection* true) and `has_one`: one query (per
  # `in_clause_limit` tuples) for every distinct owner key tuple.
  def self.preload_has(records : Array(Grant::Base), name : String, foreign_keys : Array(String),
                       primary_keys : Array(String), loader : TupleLoader, collection : Bool) : Nil
    tuples = distinct_tuples(records, primary_keys)
    grouped = {} of String => Array(Grant::Base)
    tuples.each_slice(Grant.settings.in_clause_limit) do |chunk|
      loader.call(chunk).each do |target|
        (grouped[identity(foreign_keys.map { |column| target.read_attribute(column) })] ||= [] of Grant::Base) << target
      end
    end

    inverse = records.first?.try(&._association_inverse(name))
    records.each do |record|
      found = key_values(record, primary_keys).try { |values| grouped[identity(values)]? }
      if collection
        targets = found || [] of Grant::Base
        record.set_loaded_association(name, targets)
        targets.each do |target|
          record._adopt_strict_loading(target, true)
          target.set_loaded_association(inverse, record) if inverse
        end
      else
        target = found.try(&.first?)
        record.set_loaded_association(name, target)
        record._adopt_strict_loading(target, false)
        target.set_loaded_association(inverse, record) if target && inverse
      end
    end
  end

  # Dependent rows of *owner* (for `dependent: :destroy`).
  def self.dependents_of(owner : Grant::Base, target : T.class, foreign_keys : Array(String), primary_keys : Array(String)) : Array(T) forall T
    values = key_values(owner, primary_keys)
    return [] of T unless values
    T.current_scope.where_tuples(foreign_keys, [values]).select
  end

  # `dependent: :nullify`: one UPDATE clearing the foreign key columns.
  def self.nullify_dependents(owner : Grant::Base, target : T.class, foreign_keys : Array(String), primary_keys : Array(String)) : Nil forall T
    values = key_values(owner, primary_keys)
    return unless values
    assignments = foreign_keys.map { |column| {column, nil.as(Grant::Columns::Type)} }
    T.unscoped.where_tuples(foreign_keys, [values]).update_all(assignments)
  end

  # `dependent: :delete_all`: one DELETE, no callbacks.
  def self.delete_dependents(owner : Grant::Base, target : T.class, foreign_keys : Array(String), primary_keys : Array(String)) : Nil forall T
    values = key_values(owner, primary_keys)
    return unless values
    T.unscoped.where_tuples(foreign_keys, [values]).delete_all
  end

  private def self.distinct_tuples(records : Array(Grant::Base), columns : Array(String)) : Array(Array(Grant::Columns::Type))
    seen = Set(String).new
    tuples = [] of Array(Grant::Columns::Type)
    records.each do |record|
      values = key_values(record, columns) || next
      tuples << values if seen.add?(identity(values))
    end
    tuples
  end

  # The inverse of a `belongs_to` when it is a `has_one` on the target.
  private def self.singular_inverse(records : Array(Grant::Base), name : String) : String?
    owner = records.first? || return nil
    reflection = Grant::AssociationRegistry.reflection(owner.class.name, name) || return nil
    inverse = reflection.inverse_of || return nil
    inverse.has_one? ? inverse.name : nil
  end
end
