require "./builder"
require "./sql_expression"

# Computed columns from `select("COUNT(*) AS n")` are not model columns. They
# are read into a per-record hash so they stay reachable without touching the
# fixed column mapping.
module Grant::Query::SelectExtras
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @extra_attributes : Hash(String, Grant::Columns::Type)? = nil

  # Values of the result columns that are not model columns, keyed by name or
  # alias. Empty for a record loaded without a computed `select`.
  def extra_attributes : Hash(String, Grant::Columns::Type)
    @extra_attributes || {} of String => Grant::Columns::Type
  end

  # The computed column *name* (`select("COUNT(*) AS n")` is `"n"`), or `nil`
  # when the record has no such column.
  def extra_attribute(name : String | Symbol) : Grant::Columns::Type
    @extra_attributes.try(&.[name.to_s]?)
  end

  # The computed column *name* as *type*. Raises `TypeCastError` naming the
  # column when the database returned another type (or no such column, unless
  # *type* is nilable); cast in SQL (`CAST(x AS BIGINT)`) when the type
  # differs between adapters.
  def extra_attribute(name : String | Symbol, type : T.class) : T forall T
    value = extra_attribute(name)
    return value if value.is_a?(T)

    raise TypeCastError.new("Extra attribute #{name.to_s.inspect} is #{value.class}, not #{T}")
  end

  # :nodoc:
  def store_extra_attribute(name : String, value : Grant::Columns::Type) : Nil
    (@extra_attributes ||= {} of String => Grant::Columns::Type)[name] = value
  end
end

abstract class Grant::Base
  include Grant::Query::SelectExtras
end

class Grant::Query::Builder(Model)
  # Restricts the SELECT list to columns and SQL expressions. A `Symbol` is a
  # column; a `String` is a trusted expression, optionally aliased, that comes
  # back through `record.extra_attribute("alias")`.
  #
  # ```
  # Order.group(:status).select(:status, "COUNT(*) AS total").each do |row|
  #   row.status
  #   row.extra_attribute("total", Int64)
  # end
  # ```
  def select!(*columns : Symbol | String) : self
    reset_load_state
    @select_columns = columns.map do |column|
      column.is_a?(String) ? Grant::Query::SqlExpression.validate!(column, "SELECT expression") : column.to_s
    end.to_a
    self
  end

  def select(*columns : Symbol | String) : self
    chain_copy.select!(*columns)
  end

  def reselect!(*columns : String) : self
    select!(*columns)
  end

  def reselect(*columns : String) : self
    chain_copy.select!(*columns)
  end
end
