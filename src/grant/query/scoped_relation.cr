# Helpers used when named scopes create their model-specific relation subtype.
class Grant::Query::Builder(Model)
  # The boolean connector is carried into a model-specific relation when a
  # named scope starts from the model's current query.
  def boolean_operator : Symbol
    @boolean_operator
  end

  # Copy query state into a different Builder subtype for the same model.
  # Named scopes use this to retain defaults and existing relation clauses.
  def copy_state_to(target : Grant::Query::Builder(Model)) : Nil
    target.default_scope_where_fields.concat(default_scope_where_fields)
    target.where_fields.concat(where_fields)
    target.order_fields.concat(order_fields)
    target.group_fields.concat(group_fields)
    target.limit(limit) if limit
    target.offset(offset) if offset
    target.eager_load_associations.concat(eager_load_associations)
    target.preload_associations.concat(preload_associations)
    target.includes_associations.concat(includes_associations)
    if mode = lock_mode
      target.lock(mode)
    end
    target.join_clauses.concat(join_clauses)
    target.distinct if distinct?
    target.having_clauses.concat(having_clauses)
    target.none if is_none?
    target.select_columns = select_columns.try(&.dup)
    target.index_hints.concat(index_hints)
    target.copy_in_chunk_size_from(self)
  end

  # Merge a plain Builder returned by a scope without requiring the caller's
  # receiver to have the same concrete Builder subtype.
  def merge_builder(other : Grant::Query::Builder(Model)) : self
    where_fields.concat(other.where_fields)

    if other.order_fields.any?
      order_fields.clear
      order_fields.concat(other.order_fields)
    end

    other.group_fields.each do |field|
      group_fields << field unless group_fields.includes?(field)
    end

    if query_limit = other.limit
      limit(query_limit)
    end
    if query_offset = other.offset
      offset(query_offset)
    end

    eager_load_associations.concat(other.eager_load_associations).uniq!
    preload_associations.concat(other.preload_associations).uniq!
    includes_associations.concat(other.includes_associations).uniq!

    if mode = other.lock_mode
      lock(mode)
    end

    other.join_clauses.each do |clause|
      join_clauses << clause unless join_clauses.includes?(clause)
    end

    distinct if other.distinct?
    having_clauses.concat(other.having_clauses)
    none if other.is_none?
    self
  end

  protected def copy_in_chunk_size_from(source : Grant::Query::Builder(Model)) : Nil
    @in_chunk_size = source.@in_chunk_size
  end
end
