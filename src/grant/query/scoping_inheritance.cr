require "./builder"

# What `Model.scoping { }` applies beyond the relation's own model: subclasses
# of the scoped class (single table inheritance) see the scope, and records
# built inside the block start from the scope's attributes, as in ActiveRecord.
class Fiber
  # Depth of row hydration in progress on this fiber while a `scoping { }`
  # block is open. Hydrating a row builds a blank record first; scope
  # attributes must not seed it.
  # :nodoc:
  property grant_hydrating : Int32 = 0
end

# The clauses of a relation, copied out so a model of the same table can merge
# them without the merge knowing this relation's model type. Folding a parent
# class's scope into a subclass relation through `Builder(Model)` on both
# sides would instantiate the merge once per pair of models.
# :nodoc:
class Grant::Query::ForeignRelation
  getter where_fields : Array(Grant::Query::WhereField)
  getter order_fields : Array(NamedTuple(field: String, direction: Grant::Query::Builder::Sort))
  getter group_fields : Array(NamedTuple(field: String))
  getter join_clauses : Array(NamedTuple(type: Symbol, table: String, on: String))
  getter having_clauses : Array(NamedTuple(stmt: String, value: Grant::Columns::Type))
  getter includes_associations : Array(Grant::Includes)
  getter preload_associations : Array(Grant::Includes)
  getter eager_load_associations : Array(Grant::Includes)
  getter index_hints : Array(Grant::Query::IndexHint)
  getter select_columns : Array(String)?
  getter limit : Int64?
  getter offset : Int64?
  getter? distinct : Bool
  getter? none : Bool
  getter? readonly : Bool
  getter? strict_loading : Bool
  getter optimizer_hints : Array(String)
  getter create_with_defaults : Hash(String, Grant::Columns::Type)
  getter lock_mode : Grant::Locking::LockMode?
  getter lock_clause : Grant::Locking::Clause?

  def initialize(@where_fields, @order_fields, @group_fields, @join_clauses, @having_clauses,
                 @includes_associations, @preload_associations, @eager_load_associations,
                 @index_hints, @select_columns, @limit, @offset, @distinct, @none, @readonly,
                 @strict_loading, @optimizer_hints, @create_with_defaults, @lock_mode, @lock_clause)
  end
end

# :nodoc:
class Grant::Query::RelationState
  def self.from_foreign_relation(db_type : Grant::Query::DbType, other : Grant::Query::ForeignRelation) : Grant::Query::RelationState
    state = new(db_type)
    state.own_where_fields.concat(other.where_fields)
    state.own_order_fields.concat(other.order_fields)
    state.own_group_fields.concat(other.group_fields)
    state.own_join_clauses.concat(other.join_clauses)
    state.own_having_clauses.concat(other.having_clauses)
    state.own_includes_associations.concat(other.includes_associations)
    state.own_preload_associations.concat(other.preload_associations)
    state.own_eager_load_associations.concat(other.eager_load_associations)
    state.own_index_hints.concat(other.index_hints)
    state.select_columns = other.select_columns
    state.limit = other.limit
    state.offset = other.offset
    state.distinct = other.distinct?
    state.is_none = other.none?
    state.readonly = true if other.readonly?
    state.strict_loading = other.strict_loading?
    state.optimizer_hints = other.optimizer_hints.dup
    if mode = other.lock_mode
      state.lock_mode = mode
    elsif clause = other.lock_clause
      state.lock_clause = clause
    end
    state
  end
end

abstract class Grant::Scoping::ScopeEntry
  # The entry's relation as clauses a relation over another model of the same
  # table can merge, or nil when the entry hides the scope instead.
  # :nodoc:
  abstract def foreign_relation : Grant::Query::ForeignRelation?
end

class Grant::Scoping::RelationEntry(Model) < Grant::Scoping::ScopeEntry
  def foreign_relation : Grant::Query::ForeignRelation?
    other = @relation
    Grant::Query::ForeignRelation.new(
      other.where_fields, other.order_fields, other.group_fields, other.join_clauses,
      other.having_clauses, other.includes_associations, other.preload_associations,
      other.eager_load_associations, other.index_hints, other.select_columns.try(&.dup),
      other.limit, other.offset, other.distinct?, other.is_none?, other.readonly?,
      other.strict_loading?, other.optimizer_hint_list, other.create_with_attributes,
      other.lock_mode, other.lock_clause)
  end
end

class Grant::Scoping::UnscopedEntry < Grant::Scoping::ScopeEntry
  # An `unscoped { }` block hides the scope of the model it names, and with it
  # whatever a parent class scoped.
  def foreign_relation : Grant::Query::ForeignRelation?
    nil
  end
end

module Grant::Scoping
  # Runs *block* while records are being hydrated from rows, so a record built
  # for it does not take scope attributes from an open `scoping { }` block.
  # Costs one fiber-slot read when no block is open.
  def self.hydrating(& : -> T) : T forall T
    fiber = Fiber.current
    return yield unless fiber.grant_scoping_stacks

    fiber.grant_hydrating += 1
    begin
      yield
    ensure
      fiber.grant_hydrating -= 1
    end
  end

  # Folds the `scoping { }` relation of the nearest parent class in *lineage*
  # (this class first, then its model superclasses) into *target*. The class's
  # own relation is handled by `current_relation`, so it is skipped here.
  def self.merge_inherited(target : Grant::Query::Builder(M), lineage : Array(String)) : Grant::Query::Builder(M) forall M
    stacks = Fiber.current.grant_scoping_stacks
    return target unless stacks

    lineage.each_with_index do |name, index|
      next if index == 0

      stack = stacks[name]?
      next if stack.nil? || stack.empty?

      if foreign = stack.last.foreign_relation
        target.merge_foreign_relation!(foreign)
      end
      break
    end
    target
  end

  # True when a `scoping { }` block of this fiber covers a model in *lineage*.
  def self.covers?(lineage : Array(String)) : Bool
    stacks = Fiber.current.grant_scoping_stacks
    return false unless stacks

    lineage.any? do |name|
      stack = stacks[name]?
      !stack.nil? && !stack.empty? && !stack.last.is_a?(UnscopedEntry)
    end
  end

  # The attributes a record built now should start with: the equality
  # predicates and `create_with` defaults of the `scoping { }` relation that
  # covers *model*. Empty outside a block, while hydrating a row, or for a
  # model no block covers.
  def self.new_record_attributes(model : Model.class) : Hash(String, Grant::Columns::Type) forall Model
    fiber = Fiber.current
    return {} of String => Grant::Columns::Type unless fiber.grant_scoping_stacks
    return {} of String => Grant::Columns::Type if fiber.grant_hydrating > 0
    return {} of String => Grant::Columns::Type unless covers?(model.__lineage_names)

    model.current_scope.new_record_attributes
  end
end

class Grant::Query::Builder(Model)
  # Attributes a record built from this relation starts with: scope attributes
  # overlaid with `create_with` defaults.
  # :nodoc:
  def new_record_attributes : Hash(String, Grant::Columns::Type)
    attributes_for_new_record
  end

  # Merges the clauses of *other*, a relation over a different model class of
  # the same table (a parent class in a single-table hierarchy), into this one
  # as `merge` would. Default-scope clauses are not copied; this model has its
  # own.
  # :nodoc:
  def merge_foreign_relation!(other : Grant::Query::ForeignRelation) : self
    staged = Grant::Query::Builder(Model).new(@relation_state.db_type)
    staged.relation_state = Grant::Query::RelationState.from_foreign_relation(@relation_state.db_type, other)
    staged.adopt_create_with_defaults(other.create_with_defaults)
    merge!(staged)
  end
end
