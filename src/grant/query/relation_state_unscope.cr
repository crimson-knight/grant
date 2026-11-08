require "./builder"

# :nodoc:
class Grant::Query::RelationState
  def unscope_component!(component : Symbol, extra : Proc(Symbol, Bool)) : Nil
    return if unscope_query_clause!(component)
    return if unscope_relation_option!(component)
    return if extra.call(component)

    raise ArgumentError.new("unscope: unknown component #{component.inspect}")
  end

  private def unscope_query_clause!(component : Symbol) : Bool
    case component
    when :where
      clear_where_fields
      true
    when :order
      clear_order_fields
      true
    when :limit
      @limit = nil
      true
    when :offset
      @offset = nil
      true
    when :group, :group_by
      clear_group_fields
      true
    when :having
      clear_having_clauses
      true
    when :joins
      drop_join_clauses(false)
      true
    when :left_joins, :left_outer_joins
      drop_join_clauses(true)
      true
    when :select
      @select_columns = nil
      true
    when :distinct
      @distinct = false
      true
    else
      false
    end
  end

  private def unscope_relation_option!(component : Symbol) : Bool
    case component
    when :lock
      @lock_mode = nil
      @lock_clause = nil
      true
    when :readonly
      @readonly = false
      true
    when :optimizer_hints
      @optimizer_hints = [] of String
      true
    else
      false
    end
  end

  private def drop_join_clauses(left : Bool) : Nil
    return unless @join_clauses.any? { |clause| (clause[:type] == :left) == left }

    own_join_clauses.reject! { |clause| (clause[:type] == :left) == left }
  end
end
