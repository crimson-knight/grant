require "./builder"

# Copies the relation components that need no model-specific interpretation.
# :nodoc:
class Grant::Query::RelationState
  def merge_order_fields!(other : Grant::Query::RelationState, replacing : Bool) : Nil
    if replacing
      self.order_fields = other.order_fields.dup
    else
      other.order_fields.each do |term|
        own_order_fields << term unless @order_fields.includes?(term)
      end
    end
  end

  def merge_components_from!(other : Grant::Query::RelationState, include_select : Bool = true, include_strict_loading : Bool = true) : Nil
    other.group_fields.each do |field|
      own_group_fields << field unless @group_fields.includes?(field)
    end

    if include_select
      if other_columns = other.select_columns
        if current_columns = @select_columns
          @select_columns = (current_columns + other_columns).uniq
        else
          @select_columns = other_columns.dup
        end
      end
    end

    @limit = other.limit if other.limit
    @offset = other.offset if other.offset

    own_eager_load_associations.concat(other.eager_load_associations).uniq!
    own_preload_associations.concat(other.preload_associations).uniq!
    own_includes_associations.concat(other.includes_associations).uniq!
    @strict_loading = true if include_strict_loading && other.strict_loading?

    if mode = other.lock_mode
      @lock_clause = nil
      @lock_mode = mode
    elsif clause = other.lock_clause
      @lock_mode = nil
      @lock_clause = clause
    end

    other.join_clauses.each do |join_clause|
      own_join_clauses << join_clause unless @join_clauses.includes?(join_clause)
    end

    @distinct = true if other.distinct?
    own_having_clauses.concat(other.having_clauses)
    @is_none = true if other.is_none?
    @readonly = true if other.readonly
    @optimizer_hints = @optimizer_hints | other.optimizer_hints
  end

  def merge_scope_components_from!(other : Grant::Query::RelationState) : Nil
    merge_components_from!(other, include_select: false, include_strict_loading: false)
  end
end

# State and helpers behind `merge`, `reorder` and the later `unscope`
# components: whether the relation was reordered, and which clauses were
# unscoped, so merging a relation applies its unscoping as well.
# What a relation remembers beyond its clauses, kept in one object so a plain
# relation pays for a single nil pointer. Instances are never changed once
# built: every note builds a new one, so copies that share it cannot leak
# changes into each other.
class Grant::Query::RelationNotes
  EMPTY = new

  getter? reordering : Bool
  getter unscoped_components : Array(Symbol)
  getter unscoped_columns : Array(String)
  getter eager_load_joins : Array(Grant::Query::JoinSupport::Clause)
  getter? eager_load_distinct : Bool

  def initialize(@reordering : Bool = false,
                 @unscoped_components : Array(Symbol) = [] of Symbol,
                 @unscoped_columns : Array(String) = [] of String,
                 @eager_load_joins : Array(Grant::Query::JoinSupport::Clause) = [] of Grant::Query::JoinSupport::Clause,
                 @eager_load_distinct : Bool = false)
  end

  def with(reordering : Bool = @reordering,
           unscoped_components : Array(Symbol) = @unscoped_components,
           unscoped_columns : Array(String) = @unscoped_columns,
           eager_load_joins : Array(Grant::Query::JoinSupport::Clause) = @eager_load_joins,
           eager_load_distinct : Bool = @eager_load_distinct) : RelationNotes
    RelationNotes.new(reordering, unscoped_components, unscoped_columns, eager_load_joins, eager_load_distinct)
  end

  # Removes only the JOIN clauses and DISTINCT that eager_load added. Nil
  # means no eager-load additions need to be removed.
  def drop_eager_load_joins_from : NamedTuple(join_clauses: Array(Grant::Query::JoinSupport::Clause), distinct: Bool, notes: RelationNotes)?
    return if eager_load_joins.empty? && !eager_load_distinct?

    empty_joins = [] of Grant::Query::JoinSupport::Clause
    {join_clauses: eager_load_joins, distinct: eager_load_distinct?, notes: self.with(eager_load_joins: empty_joins, eager_load_distinct: false)}
  end
end

class Grant::Query::Builder(Model)
  @notes : Grant::Query::RelationNotes? = nil

  protected def notes : Grant::Query::RelationNotes
    @notes || Grant::Query::RelationNotes::EMPTY
  end

  # `true` after `reorder`, so a relation merged into another replaces its
  # ORDER BY instead of appending to it.
  def reordering? : Bool
    notes.reordering?
  end

  # Clears the ORDER BY and marks the relation as reordered.
  protected def start_reordering! : Nil
    clear_order_fields
    @notes = notes.with(reordering: true) unless reordering?
  end

  protected def record_unscope(components : Array(Symbol)) : Nil
    return if components.empty?

    @notes = notes.with(unscoped_components: notes.unscoped_components | components)
  end

  protected def record_unscoped_columns(names : Array(String)) : Nil
    return if names.empty?

    @notes = notes.with(unscoped_columns: notes.unscoped_columns | names)
  end

  protected def unscoped_components : Array(Symbol)
    notes.unscoped_components
  end

  protected def unscoped_columns : Array(String)
    notes.unscoped_columns
  end

  # Applies the unscoping *other* did (`other.unscope(:where, where: :id)`) to
  # this relation, as ActiveRecord's `merge` does.
  protected def merge_unscopes!(other : Builder(Model)) : Nil
    components = other.unscoped_components
    columns = other.unscoped_columns
    unscope_components!(components) unless components.empty?
    unscope_where_columns!(columns) unless columns.empty?
    record_unscope(components)
  end

  # Appends the ORDER BY terms of *other* (skipping terms already present), or
  # replaces ours with them when *other* was reordered.
  protected def merge_order!(other : Builder(Model)) : Nil
    if other.reordering?
      @relation_state.merge_order_fields!(other.relation_state, true)
      @notes = notes.with(reordering: true)
    else
      @relation_state.merge_order_fields!(other.relation_state, false)
    end
  end

  # Remembers the JOIN clauses (and the DISTINCT) that `eager_load` added, so
  # `unscope(:eager_load)` can take them back.
  protected def record_eager_load_joins(added : Array(Grant::Query::JoinSupport::Clause), distinct_added : Bool) : Nil
    return if added.empty? && !distinct_added

    @notes = notes.with(eager_load_joins: notes.eager_load_joins + added, eager_load_distinct: notes.eager_load_distinct? || distinct_added)
  end

  # Removes the joins and DISTINCT `eager_load` added, for `unscope(:eager_load)`.
  protected def drop_eager_load_joins! : Nil
    if removal = notes.drop_eager_load_joins_from
      reset_load_state
      @relation_state.own_join_clauses.reject! { |clause| removal[:join_clauses].includes?(clause) }
      @relation_state.distinct = false if removal[:distinct]
      @notes = removal[:notes]
    end
  end

  # Drops the LEFT JOIN clauses (`left: true`) or every other join clause.
  protected def drop_join_clauses!(left : Bool) : Nil
    return unless @relation_state.join_clauses.any? { |clause| (clause[:type] == :left) == left }

    own_join_clauses.reject! { |clause| (clause[:type] == :left) == left }
  end

  # Components `unscope` accepts that carry relation state of their own.
  protected def unscope_relation_state!(component : Symbol) : Bool
    case component
    when :annotate
      @query_annotation = nil
    when :create_with
      @create_with_defaults = nil
    when :reordering
      @notes = notes.with(reordering: false) if reordering?
    when :strict_loading
      @relation_state.strict_loading = false
    when :extending
      # A relation holds no extension modules in Grant (`extending` is a model
      # macro, resolved at compile time), so there is nothing to remove.
    else
      return false
    end

    true
  end
end
