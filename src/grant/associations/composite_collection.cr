# Lazy, owner-scoped collection returned by a `has_many` with a composite
# foreign key. It reads the preloaded records when `includes` loaded them and
# queries by the whole key tuple otherwise; anything it does not define is
# forwarded to the owner-scoped `Grant::Query::Builder` (`where`, `order`,
# `limit`, `pluck`, ...).
#
# ```
# order.items.to_a
# order.items.where(state: "open").count
# order.items.create!(sku: "A-1")
# ```
class Grant::CompositeCollection(Owner, Target)
  include Enumerable(Target)

  def initialize(@owner : Owner, @association_name : String, @foreign_keys : Array(String),
                 @primary_keys : Array(String),
                 @scope : Proc(Grant::Query::Builder(Target), Grant::Query::Builder(Target))? = nil,
                 @loaded_records : Array(Target)? = nil,
                 @strict_loading_option : Bool? = nil,
                 @inverse_name : String? = nil)
  end

  getter owner : Owner

  # True when the records are cached on the owner (by `includes` or a load).
  def loaded? : Bool
    !@loaded_records.nil?
  end

  # The owner's key tuple, or nil while any part is unset.
  def owner_key : Array(Grant::Columns::Type)?
    Grant::CompositeAssociation.key_values(@owner, @primary_keys)
  end

  # The owner-scoped relation: the target's current scope, the association
  # scope, and `(fk_a, fk_b) = (?, ?)`. An owner without a full key matches
  # nothing.
  def relation : Grant::Query::Builder(Target)
    relation = Target.current_scope
    scope = @scope
    relation = scope.call(relation) if scope
    values = owner_key
    return relation.none unless values
    relation.where_tuples(@foreign_keys, [values])
  end

  # Loads the records if needed and returns them.
  def all : Array(Target)
    if records = @loaded_records
      return records
    end
    @owner.assert_association_can_lazy_load!(@association_name, @strict_loading_option)
    records = relation.select
    records.each { |record| adopt(record) }
    records
  end

  def to_a : Array(Target)
    all
  end

  def each(& : Target ->) : Nil
    all.each { |record| yield record }
  end

  # Forgets the cached records so the next read queries again.
  def reset : self
    @loaded_records = nil
    @owner.reset_association(@association_name)
    self
  end

  # Discards the cached records and loads them again with one query.
  def reload : self
    reset
    all
    self
  end

  # Number of records: the loaded ones, else one `COUNT(*)`.
  def size : Int64
    if records = @loaded_records
      records.size.to_i64
    else
      count
    end
  end

  # One `COUNT(*)` within the owner's key, without loading records.
  def count : Int64
    @owner.assert_association_can_lazy_load!(@association_name, @strict_loading_option)
    result = relation.count
    result.is_a?(Int64) ? result : result.values.sum
  end

  def empty? : Bool
    if records = @loaded_records
      records.empty?
    else
      @owner.assert_association_can_lazy_load!(@association_name, @strict_loading_option)
      !relation.exists?
    end
  end

  def any? : Bool
    !empty?
  end

  def none? : Bool
    empty?
  end

  def first : Target?
    all.first?
  end

  def last : Target?
    all.last?
  end

  # Builds a new target carrying this owner's key in its foreign key columns.
  def build(**attributes) : Target
    build(model_args(attributes))
  end

  # :ditto:
  def build(attributes : Grant::ModelArgs) : Target
    record = Target.new
    record.set_attributes(attributes)
    if values = owner_key
      Grant::CompositeAssociation.assign_key(record, @foreign_keys, values)
    end
    @loaded_records.try { |records| records << record }
    adopt(record)
    record
  end

  # Builds and saves a target. Raises `Grant::Associations::OwnerNotSaved` when
  # the owner is not persisted.
  def create(**attributes) : Target
    create_record(model_args(attributes), false)
  end

  # Like `create`, raising `Grant::RecordNotSaved` when the target is invalid.
  def create!(**attributes) : Target
    create_record(model_args(attributes), true)
  end

  # Points *record* at this owner and saves it once the owner is saved.
  def <<(record : Target) : self
    if values = owner_key
      Grant::CompositeAssociation.assign_key(record, @foreign_keys, values)
    end
    @loaded_records.try { |records| records << record unless records.includes?(record) }
    adopt(record)
    record.save if @owner.persisted?
    self
  end

  # Anything else (`where`, `order`, `limit`, `pluck`, ...) runs on the
  # owner-scoped relation.
  forward_missing_to relation

  private def create_record(attributes : Grant::ModelArgs, bang : Bool) : Target
    unless @owner.persisted?
      raise Grant::Associations::OwnerNotSaved.new(@owner, @association_name, bang ? "create!" : "create")
    end
    record = build(attributes)
    bang ? record.save! : record.save
    record
  end

  private def adopt(record : Target) : Nil
    if inverse = @inverse_name
      record.set_loaded_association(inverse, @owner)
    end
  end

  private def model_args(attributes : NamedTuple) : Grant::ModelArgs
    args = Grant::ModelArgs.new
    attributes.each { |key, value| args[key.to_s] = value.as(Grant::Columns::Type) }
    args
  end
end
