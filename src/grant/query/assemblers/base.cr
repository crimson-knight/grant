require "../../aggregations"

module Grant::Query::Assembler
  abstract class Base(Model)
    include Grant::Aggregations::QueryMethods
    @placeholder : String = ""
    @where : String?
    @order : String?
    @limit : String?
    @offset : String?
    @group_by : String?
    @having : String?
    @joins : String?
    @lock : String?

    def initialize(@query : Builder(Model))
      @numbered_parameters = [] of Grant::Columns::Type
      @aggregate_fields = [] of String
    end

    abstract def add_parameter(value : Grant::Columns::Type) : String

    def numbered_parameters
      @numbered_parameters
    end

    def add_aggregate_field(name : String)
      @aggregate_fields << name
    end

    def table_name
      Model.table_name
    end

    def field_list
      fields = [Model.fields].flatten.join ", "
      fields
    end

    # Generates the SELECT keyword with optional DISTINCT modifier.
    #
    # ```
    # select_keyword # => "SELECT" or "SELECT DISTINCT"
    # ```
    def select_keyword : String
      @query.distinct? ? "SELECT DISTINCT" : "SELECT"
    end

    # Generates JOIN clauses from the query builder's join_clauses array.
    #
    # Supports INNER JOIN and LEFT JOIN types.
    #
    # ```
    # joins # => "INNER JOIN posts ON posts.user_id = users.id"
    # ```
    def joins : String?
      return @joins if @joins

      join_clauses = @query.join_clauses
      return nil if join_clauses.empty?

      parts = join_clauses.map do |jc|
        join_type = case jc[:type]
                    when :inner then "INNER JOIN"
                    when :left  then "LEFT JOIN"
                    else             "JOIN"
                    end
        "#{join_type} #{jc[:table]} ON #{jc[:on]}"
      end

      @joins = parts.join(" ")
    end

    # Generates the HAVING clause for aggregate filtering.
    #
    # HAVING clauses are applied after GROUP BY and filter grouped
    # results based on aggregate conditions.
    #
    # ```
    # having # => "HAVING COUNT(*) > 5 AND SUM(amount) > 100"
    # ```
    def having : String?
      return @having if @having

      having_clauses = @query.having_clauses
      return nil if having_clauses.empty?

      parts = having_clauses.map do |hc|
        if !hc[:value].nil?
          param_token = add_parameter(hc[:value])
          hc[:stmt].gsub(@placeholder, param_token)
        else
          hc[:stmt]
        end
      end

      @having = "HAVING #{parts.join(" AND ")}"
    end

    def build_sql(&)
      clauses = [] of String?
      yield clauses
      clauses.compact!.join " "
    end

    def where
      return @where if @where

      clauses = ["WHERE"]

      @query.where_fields.each do |expression|
        clauses << expression[:join].to_s.upcase unless clauses.size == 1

        if expression[:field]?.nil? # custom SQL
          expression = expression.as(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))

          if !expression[:value].nil?
            param_token = add_parameter expression[:value]
            clause = expression[:stmt].gsub(@placeholder, param_token)
          else
            clause = expression[:stmt]
          end

          clauses << clause
        else # standard where query
          expression = expression.as(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
          add_aggregate_field expression[:field]

          if expression[:value].nil?
            clauses << "#{expression[:field]} IS NULL"
          elsif expression[:value].is_a?(Array)
            in_stmt = String.build do |str|
              str << '('
              expression[:value].as(Array).each_with_index do |val, idx|
                case val
                when Bool, Number
                  str << val
                else
                  str << add_parameter val
                end
                str << ',' if expression[:value].as(Array).size - 1 != idx
              end
              str << ')'
            end
            clauses << "#{expression[:field]} #{sql_operator(expression[:operator])} #{in_stmt}"
          else
            clauses << "#{expression[:field]} #{sql_operator(expression[:operator])} #{add_parameter expression[:value]}"
          end
        end
      end

      return nil if clauses.size == 1

      @where = clauses.join(" ")
    end

    def order(use_default_order = true)
      return @order if @order

      order_fields = @query.order_fields

      if order_fields.none?
        if use_default_order
          order_fields = default_order
        else
          return nil
        end
      end

      order_clauses = order_fields.map do |expression|
        field = expression[:field]
        next unless field
        
        add_aggregate_field field

        if expression[:direction] == Builder::Sort::Ascending
          "#{field} ASC"
        else
          "#{field} DESC"
        end
      end.compact

      @order = "ORDER BY #{order_clauses.join ", "}"
    end

    def group_by
      return @group_by if @group_by
      group_fields = @query.group_fields
      return nil if group_fields.none?
      group_clauses = group_fields.map do |expression|
        "#{expression[:field]}"
      end

      @group_by = "GROUP BY #{group_clauses.join ", "}"
    end

    def limit
      @limit ||= if limit = @query.limit
                   "LIMIT #{limit}"
                 end
    end

    def offset
      @offset ||= if offset = @query.offset
                    "OFFSET #{offset}"
                  end
    end

    def lock
      @lock ||= if lock_mode = @query.lock_mode
                  lock_mode.to_sql(Model.adapter)
                end
    end

    def log(*stuff)
    end

    def default_order
      [{field: Model.primary_name, direction: "ASC"}]
    end

    def count : (Executor::MultiValue(Model, Int64) | Executor::Value(Model, Int64))
      count_expr = @query.distinct? ? "COUNT(DISTINCT #{field_list})" : "COUNT(*)"
      sql = build_sql do |s|
        s << "SELECT #{count_expr}"
        s << "FROM #{table_name}"
        s << joins
        s << where
        s << group_by
        s << having
        s << order(use_default_order: false)
        s << limit
        s << offset
      end

      if group_by
        Executor::MultiValue(Model, Int64).new sql, numbered_parameters, default: 0_i64
      else
        Executor::Value(Model, Int64).new sql, numbered_parameters, default: 0_i64
      end
    end

    def first(n : Int32 = 1) : Executor::List(Model)
      sql = build_sql do |s|
        s << "#{select_keyword} #{field_list}"
        s << "FROM #{table_name}"
        s << joins
        s << where
        s << group_by
        s << having
        s << order
        s << "LIMIT #{n}"
        s << offset
        s << lock
      end

      Executor::List(Model).new sql, numbered_parameters
    end

    def delete
      sql = build_sql do |s|
        s << "DELETE FROM #{table_name}"
        s << joins
        s << where
      end

      log sql, numbered_parameters
      
      start_time = Time.monotonic
      begin
        result = Model.adapter.open do |db|
          db.exec sql, args: numbered_parameters
        end
        
        duration = Time.monotonic - start_time
        Grant::Logs::SQL.info &.emit("Delete executed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          rows_affected: result.rows_affected
        )
        
        result
      rescue e
        duration = Time.monotonic - start_time
        Grant::Logs::SQL.error &.emit("Delete failed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          error: e.message
        )
        raise e
      end
    end

    def select
      sql = build_sql do |s|
        s << "#{select_keyword} #{field_list}"
        s << "FROM #{table_name}"
        s << joins
        s << where
        s << group_by
        s << having
        s << order
        s << limit
        s << offset
        s << lock
      end

      Executor::List(Model).new sql, numbered_parameters
    end

    def exists? : Executor::Value(Model, Bool)
      sql = build_sql do |s|
        s << "SELECT EXISTS(SELECT 1 "
        s << "FROM #{table_name} "
        s << joins
        s << where
        s << ")"
      end

      Executor::Value(Model, Bool).new sql, numbered_parameters, default: false
    end

    def touch_all(fields : Tuple, time : Time) : Int64
      time = time.at_beginning_of_second
      
      set_parts = ["#{Model.quote("updated_at")} = #{add_parameter(time)}"]
      
      # Add any additional fields to touch
      fields.each do |field|
        set_parts << "#{Model.quote(field.to_s)} = #{add_parameter(time)}"
      end
      
      sql = build_sql do |s|
        s << "UPDATE #{table_name}"
        s << "SET #{set_parts.join(", ")}"
        s << where
      end
      
      log sql, numbered_parameters
      
      start_time = Time.monotonic
      begin
        rows_affected = Model.adapter.open do |db|
          db.exec(sql, args: numbered_parameters).rows_affected
        end
        
        duration = Time.monotonic - start_time
        Grant::Logs::SQL.info &.emit("Touch all executed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          rows_affected: rows_affected,
          fields: fields.to_a.map { |f| f.to_s.as(String) }
        )
        
        rows_affected
      rescue e
        duration = Time.monotonic - start_time
        Grant::Logs::SQL.error &.emit("Touch all failed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          error: e.message
        )
        raise e
      end
    end

    OPERATORS = {"eq": "=", "gteq": ">=", "lteq": "<=", "neq": "!=", "ltgt": "<>", "gt": ">", "lt": "<", "ngt": "!>", "nlt": "!<", "in": "IN", "nin": "NOT IN", "like": "LIKE", "nlike": "NOT LIKE"}

    def sql_operator(operator : Symbol) : String
      OPERATORS[operator.to_s]? || operator.to_s
    end
  end
end
