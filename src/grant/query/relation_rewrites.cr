require "./builder"

# The raw-SQL and list forms of `reorder`, `reselect` and `regroup`: each
# replaces its clause the way its ActiveRecord namesake does, and takes the same
# arguments as the clause it replaces (`order`, `select`, `group`).
class Grant::Query::Builder(Model)
  # A list of column names and SQL expressions, as `reselect` and `regroup`
  # take them.
  alias ColumnList = Array(Symbol) | Array(String) | Array(Symbol | String)

  # Replaces the ORDER BY with the terms in *sql*, parsed like `order(String)`
  # (columns, `column DESC`, functions of columns).
  #
  # ```
  # User.order(:name).reorder("created_at DESC, id")
  # # => ORDER BY created_at DESC, id ASC
  # ```
  def reorder!(sql : String) : self
    start_reordering!
    order!(sql)
  end

  # :ditto:
  #
  # A `Grant.sql(...)` expression is emitted as written.
  def reorder!(sql : Grant::Query::SqlExpression::Trusted) : self
    start_reordering!
    order!(sql)
  end

  # Replaces the ORDER BY with a single column and direction.
  def reorder!(field : Symbol | String, direction : Symbol, *, nulls : Symbol? = nil) : self
    start_reordering!
    # `reorder(:name, :score)` is two ascending columns, not a direction.
    if nulls.nil? && field.is_a?(Symbol) && direction != :asc && direction != :desc
      order!(field)
      order!(direction)
    else
      order!(field, direction, nulls: nulls)
    end
    self
  end

  # Replaces the ORDER BY with a column ascending and a NULL placement.
  def reorder!(field : Symbol | String, *, nulls : Symbol) : self
    start_reordering!
    order!(field, nulls: nulls)
  end

  def reorder(sql : String | Grant::Query::SqlExpression::Trusted) : self
    chain_copy.reorder!(sql)
  end

  def reorder(field : Symbol | String, direction : Symbol, *, nulls : Symbol? = nil) : self
    chain_copy.reorder!(field, direction, nulls: nulls)
  end

  def reorder(field : Symbol | String, *, nulls : Symbol) : self
    chain_copy.reorder!(field, nulls: nulls)
  end

  # Replaces the SELECT list with columns (`Symbol`) and trusted SQL
  # expressions (`String`), in any mix.
  #
  # ```
  # User.select(:id).reselect(:id, "COUNT(*) AS n")
  # ```
  def reselect!(*columns : Symbol | String) : self
    select!(*columns)
  end

  # :ditto:
  def reselect!(columns : ColumnList) : self
    reset_load_state
    @relation_state.select_columns = columns.map do |column|
      column.is_a?(String) ? Grant::Query::SqlExpression.validate!(column, "SELECT expression") : column.to_s
    end.to_a
    self
  end

  def reselect(*columns : Symbol | String) : self
    chain_copy.select!(*columns)
  end

  def reselect(columns : ColumnList) : self
    chain_copy.reselect!(columns)
  end

  # Replaces the GROUP BY with columns (`Symbol`) and trusted SQL expressions
  # (`String`), in any mix.
  #
  # ```
  # Order.group(:status).regroup("date(created_at)", :region)
  # ```
  def regroup!(*fields : Symbol | String) : self
    regroup!(fields.to_a)
  end

  # :ditto:
  def regroup!(fields : ColumnList) : self
    clear_group_fields
    fields.each do |field|
      if field.is_a?(String)
        group_by!(field)
      else
        group_by!(field)
      end
    end
    self
  end

  def regroup(*fields : Symbol | String) : self
    chain_copy.regroup!(fields.to_a)
  end

  def regroup(fields : ColumnList) : self
    chain_copy.regroup!(fields)
  end
end
