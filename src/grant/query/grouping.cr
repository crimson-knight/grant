require "./builder"
require "./sql_expression"

class Grant::Query::Builder(Model)
  # Appends a GROUP BY on one or more columns. `group` is ActiveRecord's name
  # for `group_by`; `group_by` stays because `Enumerable#group_by` takes a block
  # and the two would otherwise read alike. Returns `self`.
  #
  # ```
  # Order.group(:status)
  # Order.group(:status, :region)
  # ```
  def group!(*fields : Symbol) : self
    fields.each { |field| group_by!(field) }
    self
  end

  # Appends a GROUP BY on SQL expressions, such as `"date(created_at)"`. Each
  # expression is trusted like `order(String)`: one balanced expression, no
  # statement separator or comment marker.
  #
  # ```
  # Order.group("date(created_at)").count # => {"2026-09-28" => 3}
  # ```
  def group!(*expressions : String) : self
    expressions.each { |expression| group_by!(expression) }
    self
  end

  # :ditto:
  def group_by!(expression : String) : self
    stripped = Grant::Query::SqlExpression.validate!(expression, "GROUP BY expression")
    own_group_fields << {field: stripped}
    self
  end

  def group_by(expression : String) : self
    chain_copy.group_by!(expression)
  end

  def group(*fields : Symbol) : self
    chain_copy.group!(*fields)
  end

  def group(*expressions : String) : self
    chain_copy.group!(*expressions)
  end

  def group(fields : Array(Symbol)) : self
    chain_copy.group_by!(fields)
  end
end
