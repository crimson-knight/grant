module Grant::Aggregations
  module ClassMethods
    # Sum the values of a specific column. Integer columns sum to `Int64`, float
    # columns to `Float64`, anything else (an expression, a joined column) to
    # `Int64` or `BigDecimal`. Raises `ArgumentError` on a grouped scope; use
    # `group(...).sum(...)` on a relation for the per-group `Hash`.
    def sum(column : Symbol | String) : Grant::Query::Builder::SumValue
      result = current_scope.sum(column)
      raise ArgumentError.new("sum on a grouped scope returns a Hash per group; call it on the relation") if result.is_a?(Hash)
      result
    end

    # Calculate average of a specific column
    def avg(column : Symbol | String) : Float64?
      result = current_scope.avg(column)
      raise ArgumentError.new("avg on a grouped scope returns a Hash per group; call it on the relation") if result.is_a?(Hash)
      result
    end

    # Counts rows whose *column* is not NULL, or distinct values with
    # `distinct: true`. `count(:all)` and `count("*")` are `count`.
    def count(column : Symbol | String, distinct : Bool = false) : Int64
      result = current_scope.count(column, distinct)
      result.is_a?(Int64) ? result : result.values.sum
    end

    # Generic aggregate, like ActiveRecord's `calculate`. See
    # `Grant::Query::Builder#calculate`.
    def calculate(operation : Grant::Calculation | Symbol, column : Symbol | String | Nil = nil)
      current_scope.calculate(operation, column)
    end

    # ActiveRecord-compatible name for `avg`.
    def average(column : Symbol | String) : Float64?
      avg(column)
    end

    # Find minimum value of a specific column
    def min(column : Symbol | String) : Grant::Columns::Type
      result = current_scope.min(column)
      raise ArgumentError.new("min on a grouped scope returns a Hash per group; call it on the relation") if result.is_a?(Hash)
      result
    end

    def minimum(column : Symbol | String) : Grant::Columns::Type
      min(column)
    end

    # Find maximum value of a specific column
    def max(column : Symbol | String) : Grant::Columns::Type
      result = current_scope.max(column)
      raise ArgumentError.new("max on a grouped scope returns a Hash per group; call it on the relation") if result.is_a?(Hash)
      result
    end

    def maximum(column : Symbol | String) : Grant::Columns::Type
      max(column)
    end

    # Pluck values from a specific column
    def pluck(column : Symbol | String) : Array(Grant::Columns::Type)
      current_scope.pluck(column).map(&.first)
    end

    # Pick the first value from a specific column
    def pick(column : Symbol | String) : Grant::Columns::Type?
      query = current_scope
      if query.order_fields.empty?
        query.order_fields << {field: primary_name, direction: Grant::Query::Builder::Sort::Ascending}
      end
      query.pick(column).try(&.first)
    end

    # Get the last record
    def last : self?
      current_scope.last
    end

    # Get the last record, raise if not found
    def last! : self
      last || raise Grant::Querying::NotFound.new("No #{{{@type.name.stringify}}} found with last")
    end
  end

  # Module for query builder aggregation methods
  module QueryMethods(Model)
    private def aggregate_field(column : Symbol | String) : String
      field = column.to_s
      if @query.join_clauses.any?
        "#{Model.quote(Model.table_name)}.#{Model.quote(field)}"
      else
        Model.quote(field)
      end
    end

    # Builds the aggregate statement for *function* (`SUM`, `AVG`, `MIN`, `MAX`
    # or `COUNT`) over *column*, honoring the relation's joins, WHERE, GROUP BY,
    # HAVING, ORDER, LIMIT and OFFSET.
    #
    # - Grouped relations select the group keys ahead of the aggregate, so one
    #   GROUP BY statement answers every group.
    # - A limited or offset ungrouped relation aggregates over the rows it
    #   returns, by wrapping them in a derived table (an aggregate is one row, so
    #   a LIMIT on it would change nothing).
    # - *cast* `:text` returns the aggregate as text, so exact integers and
    #   decimals reach Crystal without a lossy driver conversion; `:double`
    #   returns a double precision number; `:none` leaves the driver type.
    # - *distinct* aggregates over distinct values (`SUM(DISTINCT x)`,
    #   `COUNT(DISTINCT x)`), never over a subquery of full rows.
    def aggregate_sql(function : String, column : String, cast : Symbol = :none, distinct : Bool = false) : String
      keyword = distinct ? "DISTINCT " : ""

      if @query.group_fields.any?
        group_keys = @query.group_fields.map do |expression|
          qualify_join_field(expression[:field], Model.quote(Model.table_name))
        end
        value = aggregate_expression(function, "#{keyword}#{aggregate_column_sql(column)}", cast)
        return build_sql do |s|
          s << "#{select_prefix} #{group_keys.join(", ")}, #{value}"
          s << from_clause
          s << joins
          s << where
          s << group_by
          s << having
          s << order(use_default_order: false)
          s << limit
          s << offset
        end
      end

      if @query.limit || @query.offset
        value = aggregate_expression(function, "#{keyword}grant_value", cast)
        inner = build_sql do |s|
          s << "SELECT #{aggregate_column_sql(column)} AS grant_value"
          s << from_clause
          s << joins
          s << where
          s << having
          s << order(use_default_order: false)
          # SQLite and MySQL reject OFFSET without LIMIT; Int64::MAX is unbounded.
          s << (limit || "LIMIT #{Int64::MAX}")
          s << offset
        end
        return "#{select_prefix} #{value} FROM (#{inner}) AS grant_limited_rows"
      end

      value = aggregate_expression(function, "#{keyword}#{aggregate_column_sql(column)}", cast)
      build_sql do |s|
        s << "#{select_prefix} #{value}"
        s << from_clause
        s << joins
        s << where
        s << having
      end
    end

    # `COUNT(*)` when *column* is `*`.
    private def aggregate_expression(function : String, argument : String, cast : Symbol) : String
      expression = "#{function}(#{argument})"
      case cast
      when :text   then "CAST(#{expression} AS #{Model.adapter.mysql? ? "CHAR" : "TEXT"})"
      when :double then double_cast_sql(expression)
      else              expression
      end
    end

    private def double_cast_sql(expression : String) : String
      if Model.adapter.mysql?
        # Adding a double makes the DECIMAL result a DOUBLE on every MySQL version.
        "(#{expression} + 0e0)"
      else
        "CAST(#{expression} AS #{Model.adapter.sqlite? ? "REAL" : "DOUBLE PRECISION"})"
      end
    end

    # A column name, `table.column` of the model or a joined table, or a trusted
    # SQL expression such as `price * quantity`. `*` stays as written.
    private def aggregate_column_sql(column : String) : String
      return "*" if column == "*"

      if Grant::Query::SqlExpression.identifier?(column)
        parts = column.split('.')
        if parts.size == 2
          unless parts[0] == Model.table_name || @query.join_clauses.any? { |join| Grant::Query::JoinSupport.qualifier(join[:table]) == parts[0] }
            raise ArgumentError.new("Unknown query table #{parts[0].inspect} for #{Model.name}")
          end
          "#{Model.quote(parts[0])}.#{Model.quote(parts[1])}"
        else
          aggregate_field(column)
        end
      else
        Grant::Query::SqlExpression.validate!(column, "aggregate expression")
      end
    end

    # Pluck with query conditions
    def pluck(column : Symbol | String) : Array(Grant::Columns::Type)
      results = [] of Grant::Columns::Type
      sql = build_sql do |s|
        s << "SELECT #{aggregate_field(column)}"
        s << "FROM #{table_name}"
        s << joins
        s << where
        s << order
        s << limit
        s << offset
      end

      adapter = Model.adapter
      adapter.open do |db|
        db.query(sql, args: adapter.normalize_bind_values(numbered_parameters)) do |rs|
          rs.each do
            value = rs.read(Grant::Columns::Type)
            results << value unless value.nil?
          end
        end
      end

      results
    end

    # Pick with query conditions
    def pick(column : Symbol | String) : Grant::Columns::Type?
      sql = build_sql do |s|
        s << "SELECT #{aggregate_field(column)}"
        s << "FROM #{table_name}"
        s << joins
        s << where
        s << order
        s << "LIMIT 1"
      end

      result = nil
      adapter = Model.adapter
      adapter.open do |db|
        db.query(sql, args: adapter.normalize_bind_values(numbered_parameters)) do |rs|
          if rs.move_next
            result = rs.read(Grant::Columns::Type)
          end
        end
      end

      result
    end

    # Last with query conditions
    def last : Model?
      # Reverse the order for last
      reverse_order = @order_fields.map { |field| Grant::Query::OrderSupport.reverse(field) }

      # If no order specified, order by primary key DESC
      if reverse_order.empty?
        reverse_order = [{field: Model.primary_name, direction: Sort::Descending}]
      end

      # Create new builder with reversed order
      new_builder = self.class.new(@db_type)
      new_builder.where_fields.concat(@where_fields)
      new_builder.group_fields.concat(@group_fields)
      reverse_order.each { |field| new_builder.order_fields << field }
      new_builder.limit = 1

      new_builder.select.first?
    end

    # Last! with query conditions
    def last! : Model
      last || raise Grant::Querying::NotFound.new("No record found")
    end

    # Update all matching records
    def update(**args) : Int64
      return 0_i64 if args.empty?

      Model.mark_write_operation

      set_parts = [] of String
      values = [] of Grant::Columns::Type

      args.each do |key, value|
        set_parts << "#{Model.quote(key.to_s)} = ?"
        values << value
      end

      # Add updated_at if model has it
      {% if Model.instance_vars.select { |ivar| ivar.annotation(Grant::Column) && ivar.name == "updated_at" }.size > 0 %}
        set_parts << "#{Model.quote("updated_at")} = ?"
        values << Time.local(Grant.settings.default_timezone)
      {% end %}

      sql = build_sql do |s|
        s << "UPDATE #{table_name}"
        s << "SET #{set_parts.join(", ")}"
        s << where
      end

      # Append where parameters after set values
      values.concat(numbered_parameters)

      adapter = Model.adapter
      adapter.open do |db|
        db.exec(sql, args: adapter.normalize_bind_values(values)).rows_affected
      end
    end
  end
end
