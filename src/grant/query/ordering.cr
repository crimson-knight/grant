require "./builder"
require "./sql_expression"

# Helpers shared by the ORDER BY terms of a relation.
module Grant::Query::OrderSupport
  alias Term = NamedTuple(field: String, direction: Grant::Query::Builder::Sort)

  RAW_DIRECTION = /\s+(asc|desc)(\s+nulls\s+(first|last))?\s*\z/i

  # Returns *term* ordered the other way. A raw term has its trailing
  # `ASC`/`DESC` (and `NULLS FIRST`/`LAST`) flipped on every comma-separated
  # part, or gains `DESC` when it names no direction.
  def self.reverse(term : Term) : Term
    if term[:direction].raw?
      {field: reverse_raw(term[:field]), direction: term[:direction]}
    else
      {field: term[:field], direction: term[:direction].reverse}
    end
  end

  def self.reverse_raw(sql : String) : String
    Grant::Query::SqlExpression.split_terms(sql).map do |part|
      if match = RAW_DIRECTION.match(part)
        flipped = match[1].downcase == "asc" ? "DESC" : "ASC"
        nulls = match[3]?.try { |placement| " NULLS #{placement.downcase == "first" ? "LAST" : "FIRST"}" } || ""
        "#{part[0, match.begin(0)]} #{flipped}#{nulls}"
      else
        "#{part} DESC"
      end
    end.join(", ")
  end

  # The `Sort` for an optional direction word and NULL placement word.
  def self.sort_for(direction : String?, nulls : String?) : Grant::Query::Builder::Sort
    descending = !direction.nil? && direction.downcase == "desc"
    placement = nulls.try(&.downcase)
    case placement
    when "first" then descending ? Grant::Query::Builder::Sort::DescendingNullsFirst : Grant::Query::Builder::Sort::AscendingNullsFirst
    when "last"  then descending ? Grant::Query::Builder::Sort::DescendingNullsLast : Grant::Query::Builder::Sort::AscendingNullsLast
    when nil     then descending ? Grant::Query::Builder::Sort::Descending : Grant::Query::Builder::Sort::Ascending
    else
      raise ArgumentError.new("nulls must be :first or :last (got #{nulls.inspect})")
    end
  end

  # Upper bound on `in_order_of` values. The CASE expression it builds cannot
  # use an index, so a longer list is a sign the ordering belongs elsewhere.
  IN_ORDER_OF_LIMIT = 1000
end

class Grant::Query::Builder(Model)
  ORDER_TERM = /\A\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)(?:\s+(asc|desc))?(?:\s+nulls\s+(first|last))?\s*\z/i

  # Appends ORDER BY terms written as SQL. Each comma-separated term of the form
  # `column [ASC|DESC] [NULLS FIRST|LAST]` (column may be `table.column`) becomes
  # a structured term. A function of columns, such as `lower(name) DESC` or
  # `coalesce(name, nickname)`, is emitted as written. Anything else (a
  # literal, an operator, a subquery) raises `ArgumentError`, as ActiveRecord
  # does, because sort strings often come from request parameters; wrap SQL you
  # wrote yourself in `Grant.sql`. Returns `self`.
  #
  # ```
  # User.order("name DESC, id")
  # User.order("lower(email) DESC")
  # User.order(Grant.sql("CASE WHEN admin THEN 0 ELSE 1 END"))
  # ```
  def order!(sql : String) : self
    append_order_terms(sql, trusted: false)
  end

  # :ditto:
  def order!(sql : Grant::Query::SqlExpression::Trusted) : self
    append_order_terms(sql.sql, trusted: true)
  end

  private def append_order_terms(sql : String, trusted : Bool) : self
    Grant::Query::SqlExpression.split_terms(sql).each do |term|
      if match = ORDER_TERM.match(term)
        own_order_fields << {field: match[1], direction: Grant::Query::OrderSupport.sort_for(match[2]?, match[3]?)}
      else
        own_order_fields << {field: raw_order_term(term, trusted), direction: Sort::Raw}
      end
    end
    self
  end

  # Validates a raw ORDER BY *term*: always a single expression, and, unless
  # *trusted*, a function of columns only.
  private def raw_order_term(term : String, trusted : Bool) : String
    expression = Grant::Query::SqlExpression.validate!(term, "ORDER BY expression")
    unless trusted || Grant::Query::SqlExpression.column_function?(expression)
      raise ArgumentError.new("ORDER BY #{expression.inspect} is not a column or a function of columns; wrap SQL you wrote in Grant.sql(...)")
    end
    expression
  end

  # Appends an ORDER BY on *field* with an explicit *direction* (`:asc` or
  # `:desc`) and, optionally, where NULLs sort (`nulls: :first` or `:last`).
  #
  # PostgreSQL and SQLite 3.30+ render `NULLS FIRST`/`NULLS LAST`. MySQL has no
  # such syntax, so it orders by `ISNULL(column)` first, which gives the same
  # rows in the same order.
  #
  # ```
  # User.order(:deleted_at, :asc, nulls: :last)
  # User.order("posts.title", :desc)
  # ```
  def order!(field : Symbol | String, direction : Symbol, *, nulls : Symbol? = nil) : self
    unless direction == :asc || direction == :desc
      raise ArgumentError.new("order direction must be :asc or :desc (got #{direction.inspect})")
    end
    name = resolve_column_alias(field.to_s)
    unless Grant::Query::SqlExpression.identifier?(name)
      raise ArgumentError.new("order with a direction takes a column name; write the direction inside the SQL for #{name.inspect}") if nulls
      expression = raw_order_term(name, trusted: false)
      own_order_fields << {field: "#{expression} #{direction == :desc ? "DESC" : "ASC"}", direction: Sort::Raw}
      return self
    end
    own_order_fields << {field: name, direction: Grant::Query::OrderSupport.sort_for(direction == :desc ? "desc" : "asc", nulls.try(&.to_s))}
    self
  end

  # :ditto:
  #
  # Ascending order with a NULL placement.
  def order!(field : Symbol | String, *, nulls : Symbol) : self
    order!(field, :asc, nulls: nulls)
  end

  # Orders rows by the position of *column*'s value in *values* and, by default,
  # keeps only rows whose value is in *values* (`filter: true`), like
  # ActiveRecord's `in_order_of`. A `nil` member matches NULL. With
  # `filter: false`, rows outside the list sort after the listed ones.
  #
  # The filter binds *values*. The ordering is a `CASE` expression, which cannot
  # use an index, so *values* is capped at
  # `Grant::Query::OrderSupport::IN_ORDER_OF_LIMIT` entries and longer lists
  # raise `ArgumentError`. String values are quoted literals in the ORDER BY
  # (ORDER BY terms carry no bind list).
  #
  # ```
  # Post.in_order_of(:status, ["published", "draft"]).select
  # ```
  def in_order_of!(column : Symbol | String, values : Array, filter : Bool = true) : self
    name = column.to_s
    unless Grant::Query::SqlExpression.identifier?(name)
      raise ArgumentError.new("in_order_of takes a column name (got #{name.inspect})")
    end
    if values.size > Grant::Query::OrderSupport::IN_ORDER_OF_LIMIT
      raise ArgumentError.new("in_order_of takes at most #{Grant::Query::OrderSupport::IN_ORDER_OF_LIMIT} values (got #{values.size})")
    end
    return none! if values.empty?

    and_in!(name, values) if filter

    qualified = order_column_sql(name)
    arms = String.build do |sql|
      values.each_with_index do |value, position|
        if value.nil?
          sql << " WHEN #{qualified} IS NULL THEN #{position}"
        else
          sql << " WHEN #{qualified} = #{order_literal(value)} THEN #{position}"
        end
      end
    end
    own_order_fields << {field: "CASE#{arms} ELSE #{values.size} END", direction: Sort::Raw}
    self
  end

  def in_order_of(column : Symbol | String, values : Array, filter : Bool = true) : self
    chain_copy.in_order_of!(column, values, filter)
  end

  def order(sql : String | Grant::Query::SqlExpression::Trusted) : self
    chain_copy.order!(sql)
  end

  def order(field : Symbol | String, direction : Symbol, *, nulls : Symbol? = nil) : self
    chain_copy.order!(field, direction, nulls: nulls)
  end

  def order(field : Symbol | String, *, nulls : Symbol) : self
    chain_copy.order!(field, nulls: nulls)
  end

  # Quotes a `column` or `table.column` reference for an expression built here.
  private def order_column_sql(name : String) : String
    parts = name.split('.')
    if parts.size == 2
      "#{Model.quote(parts[0])}.#{Model.quote(parts[1])}"
    else
      "#{Model.quote(Model.table_name)}.#{Model.quote(name)}"
    end
  end

  private def order_literal(value) : String
    case value
    when String
      escaped = value.gsub('\0', "").gsub("'", "''")
      if Model.adapter.mysql?
        "'#{escaped.gsub("\\", "\\\\")}'"
      elsif Model.adapter.postgres?
        # An E'' literal reads backslashes as escapes whatever the server's
        # standard_conforming_strings setting, so doubling them is always exact.
        "E'#{escaped.gsub("\\", "\\\\")}'"
      else
        "'#{escaped}'"
      end
    when UUID
      "'#{value}'"
    when Int, Float, Bool, Time, Symbol
      Grant::Sanitization.quote(value, Model.adapter)
    else
      raise ArgumentError.new("in_order_of cannot order by a #{value.class} value")
    end
  end
end
