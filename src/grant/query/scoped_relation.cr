# Helpers used when named scopes create their model-specific relation subtype.
class Grant::Query::Builder(Model)
  # The boolean connector is carried into a model-specific relation when a
  # named scope starts from the model's current query.
  # Copy query state into a different Builder subtype for the same model.
  # Named scopes use this to retain defaults and existing relation clauses.
  def copy_state_to(target : Grant::Query::Builder(Model)) : Nil
    target.own_default_scope_where_fields.concat(default_scope_where_fields)
    target.own_where_fields.concat(where_fields)
    target.own_order_fields.concat(order_fields)
    target.own_group_fields.concat(group_fields)
    target.limit!(limit) if limit
    target.offset!(offset) if offset
    target.own_eager_load_associations.concat(eager_load_associations)
    target.own_preload_associations.concat(preload_associations)
    target.own_includes_associations.concat(includes_associations)
    target.take_lock_from!(self)
    target.own_join_clauses.concat(join_clauses)
    target.distinct! if distinct?
    target.own_having_clauses.concat(having_clauses)
    target.none! if is_none?
    target.select_columns = select_columns.try(&.dup)
    target.own_index_hints.concat(index_hints)
    target.readonly! if readonly?
    target.add_optimizer_hints(optimizer_hint_list)
    target.copy_in_chunk_size_from(self)
    target.adopt_create_with_defaults(create_with_attributes)
  end

  # Merge a plain Builder returned by a scope without requiring the caller's
  # receiver to have the same concrete Builder subtype. Mutates the receiver;
  # callers pass a relation they own (a copy or a fresh one).
  def merge_builder(other : Grant::Query::Builder(Model)) : self
    # Same rules as `merge`: an equality on a column the other relation also
    # constrains replaces ours, and its ORDER BY is appended.
    merge_unscopes!(other)
    merge_where_fields!(other)
    merge_order!(other)

    other.group_fields.each do |field|
      own_group_fields << field unless group_fields.includes?(field)
    end

    if query_limit = other.limit
      limit!(query_limit)
    end
    if query_offset = other.offset
      offset!(query_offset)
    end

    own_eager_load_associations.concat(other.eager_load_associations).uniq!
    own_preload_associations.concat(other.preload_associations).uniq!
    own_includes_associations.concat(other.includes_associations).uniq!

    take_lock_from!(other)

    other.join_clauses.each do |clause|
      own_join_clauses << clause unless join_clauses.includes?(clause)
    end

    distinct! if other.distinct?
    own_having_clauses.concat(other.having_clauses)
    none! if other.is_none?
    readonly! if other.readonly?
    add_optimizer_hints(other.optimizer_hint_list)
    adopt_create_with_defaults(other.create_with_attributes)
    self
  end

  protected def copy_in_chunk_size_from(source : Grant::Query::Builder(Model)) : Nil
    @in_chunk_size = source.@in_chunk_size
  end
end
