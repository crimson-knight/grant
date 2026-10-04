require "./builder"

# :nodoc:
class Grant::Query::RelationState
  def unscope_component!(component : Symbol, extra : Proc(Symbol, Bool)) : Nil
    case component
    when :where
      clear_where_fields
    when :order
      clear_order_fields
    when :limit
      @limit = nil
    when :offset
      @offset = nil
    when :group, :group_by
      clear_group_fields
    when :having
      clear_having_clauses
    when :joins
      drop_join_clauses(false)
    when :left_joins, :left_outer_joins
      drop_join_clauses(true)
    when :select
      @select_columns = nil
    when :distinct
      @distinct = false
    when :lock
      @lock_mode = nil
      @lock_clause = nil
    when :readonly
      @readonly = false
    when :optimizer_hints
      @optimizer_hints = [] of String
    else
      unless extra.call(component)
        raise ArgumentError.new("unscope: unknown component #{component.inspect}")
      end
    end
  end

  private def drop_join_clauses(left : Bool) : Nil
    return unless @join_clauses.any? { |clause| (clause[:type] == :left) == left }

    own_join_clauses.reject! { |clause| (clause[:type] == :left) == left }
  end
end
