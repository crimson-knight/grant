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

abstract class Grant::Scoping::ScopeEntry
  # Folds the entry's relation into *target*, a relation over another model of
  # the same table.
  # :nodoc:
  abstract def merge_into(target : Grant::Query::Builder) : Nil
end

class Grant::Scoping::RelationEntry(Model) < Grant::Scoping::ScopeEntry
  def merge_into(target : Grant::Query::Builder) : Nil
    target.merge_foreign_relation!(@relation)
  end
end

class Grant::Scoping::UnscopedEntry < Grant::Scoping::ScopeEntry
  # An `unscoped { }` block hides the scope of the model it names, and with it
  # whatever a parent class scoped.
  def merge_into(target : Grant::Query::Builder) : Nil
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

      stack.last.merge_into(target)
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
  def merge_foreign_relation!(other : Grant::Query::Builder) : self
    staged = Grant::Query::Builder(Model).new(@db_type)
    staged.own_where_fields.concat(other.where_fields)
    staged.own_order_fields.concat(other.order_fields)
    staged.own_group_fields.concat(other.group_fields)
    staged.own_join_clauses.concat(other.join_clauses)
    staged.own_having_clauses.concat(other.having_clauses)
    staged.own_includes_associations.concat(other.includes_associations)
    staged.own_preload_associations.concat(other.preload_associations)
    staged.own_eager_load_associations.concat(other.eager_load_associations)
    staged.own_index_hints.concat(other.index_hints)
    staged.select_columns = other.select_columns.try(&.dup)
    staged.limit!(other.limit) if other.limit
    staged.offset!(other.offset) if other.offset
    staged.distinct! if other.distinct?
    staged.none! if other.is_none?
    staged.readonly! if other.readonly?
    staged.strict_loading! if other.strict_loading?
    staged.add_optimizer_hints(other.optimizer_hint_list)
    staged.adopt_create_with_defaults(other.create_with_attributes)
    if mode = other.lock_mode
      staged.lock!(mode)
    elsif clause = other.lock_clause
      staged.lock!(clause)
    end
    merge!(staged)
  end
end
