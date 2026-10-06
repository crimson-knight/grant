module Grant::Query::BuilderMethods
  # :nodoc:
  def __builder
    current_scope
  end

  # Explicit where overloads to avoid delegate splat/keyword ambiguity
  def where(**matches) : Grant::Query::Builder(self)
    __builder.where(**matches)
  end

  def where(matches) : Grant::Query::Builder(self)
    __builder.where(matches)
  end

  def where(field : Symbol | String, operator : Symbol, value : Grant::Columns::Type) : Grant::Query::Builder(self)
    __builder.where(field, operator, value)
  end

  def where(stmt : String, value : Grant::Columns::Type = nil) : Grant::Query::Builder(self)
    __builder.where(stmt, value)
  end

  def where(stmt : String, first, second, *rest) : Grant::Query::Builder(self)
    __builder.where(stmt, first, second, *rest)
  end

  def where : Grant::Query::WhereChain(self)
    __builder.where
  end

  delegate order, offset, limit, lock, group_by, to: __builder
  delegate joins, left_joins, distinct, having, none, to: __builder
  delegate reorder, reverse_order, rewhere, reselect, regroup, to: __builder
  delegate pluck, pick, in_batches, annotate, to: __builder
  delegate includes, preload, eager_load, in_chunks, to: __builder
  delegate use_index, force_index, ignore_index, to: __builder
  delegate ids, explain, unscope, to: __builder
  delegate group, left_outer_joins, in_order_of, readonly, optimizer_hints, to: __builder
  delegate extract_associated, pluck_as, pick_as, to: __builder
end
