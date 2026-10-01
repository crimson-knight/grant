require "./builder"

# State and helpers behind `merge`, `reorder` and the later `unscope`
# components: whether the relation was reordered, and which clauses were
# unscoped, so merging a relation applies its unscoping as well.
class Grant::Query::Builder(Model)
  # `true` after `reorder`, so a relation merged into another replaces its
  # ORDER BY instead of appending to it.
  @reordering : Bool = false

  # Components and WHERE columns this relation unscoped, in order. Both are
  # replaced rather than mutated, so a copy that shares them cannot leak into
  # the original.
  @unscoped_components : Array(Symbol)? = nil
  @unscoped_columns : Array(String)? = nil

  def reordering? : Bool
    @reordering
  end

  # Clears the ORDER BY and marks the relation as reordered.
  protected def start_reordering! : Nil
    clear_order_fields
    @reordering = true
  end

  protected def record_unscope(components : Array(Symbol)) : Nil
    return if components.empty?

    @unscoped_components = (@unscoped_components || [] of Symbol) | components
  end

  protected def record_unscoped_columns(names : Array(String)) : Nil
    return if names.empty?

    @unscoped_columns = (@unscoped_columns || [] of String) | names
  end

  protected def unscoped_components : Array(Symbol)
    @unscoped_components || [] of Symbol
  end

  protected def unscoped_columns : Array(String)
    @unscoped_columns || [] of String
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
      clear_order_fields
      own_order_fields.concat(other.order_fields)
      @reordering = true
    else
      other.order_fields.each do |term|
        own_order_fields << term unless @order_fields.includes?(term)
      end
    end
  end

  # JOIN clauses (and the DISTINCT) that `eager_load` added, replaced rather
  # than mutated so copies cannot leak into each other.
  @eager_load_joins : Array(Grant::Query::JoinSupport::Clause)? = nil
  @eager_load_distinct : Bool = false

  protected def record_eager_load_joins(added : Array(Grant::Query::JoinSupport::Clause), distinct_added : Bool) : Nil
    @eager_load_joins = (@eager_load_joins || [] of Grant::Query::JoinSupport::Clause) + added unless added.empty?
    @eager_load_distinct = true if distinct_added
  end

  # Removes the joins and DISTINCT `eager_load` added, for `unscope(:eager_load)`.
  protected def drop_eager_load_joins! : Nil
    if added = @eager_load_joins
      own_join_clauses.reject! { |clause| added.includes?(clause) }
      @eager_load_joins = nil
    end
    if @eager_load_distinct
      @distinct = false
      @eager_load_distinct = false
    end
  end

  # Drops the LEFT JOIN clauses (`left: true`) or every other join clause.
  protected def drop_join_clauses!(left : Bool) : Nil
    return unless @join_clauses.any? { |clause| (clause[:type] == :left) == left }

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
      @reordering = false
    when :strict_loading
      @strict_loading = false
    when :extending
      # A relation holds no extension modules in Grant (`extending` is a model
      # macro, resolved at compile time), so there is nothing to remove.
    else
      return false
    end

    true
  end
end
