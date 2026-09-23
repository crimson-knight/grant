module Grant::Query::BuilderMethods
  def __builder
    current_scope
  end

  # Explicit where overloads to avoid delegate splat/keyword ambiguity
  def where(**matches)
    __builder.where(**matches)
  end

  def where(matches)
    __builder.where(matches)
  end

  def where(field : Symbol | String, operator : Symbol, value : Grant::Columns::Type)
    __builder.where(field, operator, value)
  end

  def where(stmt : String, value : Grant::Columns::Type = nil)
    __builder.where(stmt, value)
  end

  def where : Grant::Query::WhereChain
    __builder.where
  end

  delegate order, offset, limit, lock, group_by, to: __builder
  delegate joins, left_joins, distinct, having, none, to: __builder
  delegate reorder, reverse_order, rewhere, reselect, regroup, to: __builder
  delegate pluck, pick, in_batches, annotate, to: __builder
  delegate includes, preload, eager_load, in_chunks, to: __builder
  delegate use_index, force_index, ignore_index, to: __builder
  delegate ids, explain, unscope, to: __builder
end
