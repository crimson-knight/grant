# The query side of `Grant::AssociationCollection`: the owner-scoped relation
# and the relation methods the collection forwards to it, so
# `user.posts.order(:id).limit(3).pluck(:title)` runs as one statement instead of
# hydrating the association first.
class Grant::AssociationCollection(Owner, Target)
  # The owner-scoped relation: this association's rows as a
  # `Grant::Query::Builder`, honoring the association scope, the `:through` join
  # and a polymorphic type. Every relation method below starts from it, and
  # none of them loads or changes the cached records.
  #
  # ```
  # user.posts.scope.where(published: true).count
  # ```
  def scope : Grant::Query::Builder(Target)
    ensure_lazy_loading_allowed
    association_relation
  end

  # The relation `dependent:` acts on. Unlike `scope` it ignores strict loading,
  # because destroying an owner is not a lazy read.
  #
  # :nodoc:
  def dependent_scope : Grant::Query::Builder(Target)
    association_relation
  end

  # Relation methods answered by SQL. They return a `Grant::Query::Builder` (or
  # the value) and never touch the loaded records, so the in-memory
  # `Enumerable` methods (`map`, `select { }`, `sum { }`) stay the way to work
  # on records that are already loaded.
  delegate order, offset, limit, lock, to: scope
  delegate joins, left_joins, distinct, having, none, to: scope
  delegate reorder, reverse_order, rewhere, reselect, regroup, to: scope
  delegate pluck, pick, in_batches, annotate, to: scope
  delegate includes, preload, eager_load, in_chunks, to: scope
  delegate use_index, force_index, ignore_index, to: scope
  delegate unscope, explain, to: scope
  delegate group, left_outer_joins, in_order_of, readonly, optimizer_hints, to: scope
  delegate extract_associated, pluck_as, pick_as, to: scope
  delegate find_each, find_in_batches, average, minimum, maximum, calculate, to: scope
  delegate find_sole_by, sole, to: scope

  # The sum of *column* over the association, computed by the database.
  def sum(column : Symbol | String)
    scope.sum(column)
  end

  # :ditto:
  def sum(column : Symbol | String, as type : T.class) : T forall T
    scope.sum(column, as: type)
  end

  # Restricts the selected columns, as `Builder#select(*columns)`. With a block
  # it stays `Enumerable#select`.
  def select(*columns : Symbol | String) : Grant::Query::Builder(Target)
    scope.select(*columns)
  end

  # The `where` forms of `Grant::Query::Builder`, started from the owner scope.
  def where(matches) : Grant::Query::Builder(Target)
    scope.where(matches)
  end

  # :ditto:
  def where(field : Symbol | String, operator : Symbol, value : Grant::Columns::Type) : Grant::Query::Builder(Target)
    scope.where(field, operator, value)
  end

  # :ditto:
  def where(stmt : String, value : Grant::Columns::Type = nil) : Grant::Query::Builder(Target)
    scope.where(stmt, value)
  end

  # :ditto:
  def where(stmt : String, first, second, *rest) : Grant::Query::Builder(Target)
    scope.where(stmt, first, second, *rest)
  end

  # :ditto:
  def where : Grant::Query::WhereChain(Target)
    scope.where
  end
end
