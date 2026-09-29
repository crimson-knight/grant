require "../../aggregations"

module Grant::Query::Assembler
  abstract class Base(Model)
    include Grant::Aggregations::QueryMethods(Model)
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
      fields = @query.select_columns || [Model.fields].flatten
      fields.map { |field| select_field_sql(field) }.join(", ")
    end

    protected def select_field_sql(field : String) : String
      if @query.join_clauses.empty?
        quote_reserved_field(field)
      else
        qualify_join_field(field, Model.quote(Model.table_name))
      end
    end

    # Qualifies a simple plucked model field when joins can introduce another
    # column with the same name.
    def pluck_field_sql(field : String) : String
      qualify_join_field(field, Model.quote(Model.table_name))
    end

    private def qualify_join_field(field : String, quoted_table_name : String) : String
      if !@query.join_clauses.empty? && field.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        "#{quoted_table_name}.#{Model.quote(field)}"
      else
        field
      end
    end

    private def quote_reserved_field(field : String) : String
      field.downcase == "all" ? Model.quote(field) : field
    end

    # Generates the SELECT keyword with optional DISTINCT modifier.
    #
    # ```
    # select_keyword # => "SELECT" or "SELECT DISTINCT"
    # ```
    def select_keyword : String
      @query.distinct? ? "#{select_prefix} DISTINCT" : select_prefix
    end

    # `SELECT`, followed by the relation's optimizer hints as one
    # `/*+ ... */` comment when it has any.
    def select_prefix : String
      hints = @query.optimizer_hint_list
      hints.empty? ? "SELECT" : "SELECT /*+ #{hints.join(" ")} */"
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
        # A raw join carries its whole fragment in `on`.
        next jc[:on] if jc[:type] == :raw

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
      sql = clauses.compact!.join " "
      # Prepend the query annotation (sanitized SQL comment) to the executed
      # statement so it appears in the wire SQL, not just `.raw_sql` inspection.
      if comment = @query.annotation_comment
        "#{comment} #{sql}"
      else
        sql
      end
    end

    def where
      return @where if @where

      default_scope = render_where_fields(@query.default_scope_where_fields)
      conditions = render_where_fields(@query.where_fields)

      return nil if default_scope.empty? && conditions.empty?

      @where = String.build do |sql|
        sql << "WHERE "
        if !default_scope.empty? && !conditions.empty?
          sql << "(#{default_scope}) AND (#{conditions})"
        elsif !default_scope.empty?
          sql << "(#{default_scope})"
        else
          sql << conditions
        end
      end
    end

    private def render_where_fields(fields : Array(Grant::Query::WhereField)) : String
      String.build do |sql|
        fields.each_with_index do |expression, index|
          sql << " #{expression[:join].to_s.upcase} " unless index == 0

          if expression[:field]?.nil?
            clause = case expression
                     when NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type))
                       bind_raw_statement(expression[:stmt], expression[:values])
                     else
                       expr = expression.as(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))
                       value = expr[:value]
                       bind_raw_statement(expr[:stmt], value.nil? ? [] of Grant::Columns::Type : [value])
                     end
            sql << clause
          else
            expr = expression.as(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
            field = structured_field_sql(expr[:field])
            add_aggregate_field(field)

            value = encrypted_query_value(expr[:field], expr[:value])
            if value.nil?
              case expr[:operator]
              when :eq
                sql << "#{field} IS NULL"
              when :neq, :ltgt
                sql << "#{field} IS NOT NULL"
              else
                raise ArgumentError.new("Operator #{expr[:operator].inspect} does not support nil values")
              end
            else
              if value.is_a?(Array)
                array = value.as(Array)
                if array.empty?
                  sql << (expr[:operator] == :nin ? "1=1" : "1=0")
                else
                  placeholders = array.map { |item| add_parameter(item.as(Grant::Columns::Type)) }
                  sql << "#{field} #{sql_operator(expr[:operator])} (#{placeholders.join(",")})"
                end
              else
                sql << "#{field} #{sql_operator(expr[:operator])} #{add_parameter(value)}"
              end
            end
          end
        end
      end
    end

    private def structured_field_sql(field : String) : String
      parts = field.split('.')
      unless parts.size.in?(1..2) && parts.all?(&.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/))
        raise ArgumentError.new("Invalid query field #{field.inspect}")
      end

      column = parts.last
      qualifier = parts.first if parts.size == 2
      encrypted_attribute = if qualifier.nil? || qualifier == Model.table_name
                              Grant::Encryption::EncryptedAttributeRegistry.for(Model.name)[column]?
                            end
      valid_column = if qualifier.nil? || qualifier == Model.table_name
                       Model.fields.includes?(column) || !encrypted_attribute.nil?
                     elsif Grant::Query::JoinSupport.joins?(@query.join_clauses, qualifier)
                       if association = Grant::AssociationRegistry.get(Model.name, qualifier)
                         association[:target_class].fields.includes?(column)
                       else
                         # A nested join, a through table or an alias: the name is
                         # a validated identifier and is quoted below.
                         true
                       end
                     else
                       false
                     end

      unless valid_column
        raise ArgumentError.new("Unknown query field #{field.inspect} for #{Model.name}")
      end

      column_name = encrypted_attribute.try(&.column_name) || column

      if qualifier
        "#{Model.quote(qualifier)}.#{Model.quote(column_name)}"
      elsif !@query.join_clauses.empty?
        "#{Model.quote(Model.table_name)}.#{Model.quote(column_name)}"
      else
        Model.quote(column_name)
      end
    end

    private def encrypted_query_value(field : String, value : Grant::Columns::Type) : Grant::Columns::Type
      parts = field.split('.')
      return value unless parts.size == 1 || parts.first == Model.table_name

      attribute_name = parts.last
      encrypted_attribute = Grant::Encryption::EncryptedAttributeRegistry.for(Model.name)[attribute_name]?
      return value unless encrypted_attribute
      unless encrypted_attribute.deterministic
        raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{attribute_name}")
      end

      case value
      when Nil
        nil
      when String
        Grant::Encryption.encrypt(value, Model.name, attribute_name, true)
      when Array(String)
        value.map { |item| Grant::Encryption.encrypt(item, Model.name, attribute_name, true) }
      else
        raise ArgumentError.new("Encrypted field #{attribute_name.inspect} can only be queried with String values")
      end
    end

    # Rewrites raw-clause placeholders to this assembler's local bind numbering
    # and rejects mismatched argument counts before the driver sees the SQL.
    private def bind_raw_statement(statement : String, values : Array(Grant::Columns::Type)) : String
      output = String::Builder.new
      chars = statement.chars
      dollar_tokens = {} of Int32 => String
      dollar_indices = [] of Int32
      question_count = 0
      dollar_style = false
      index = 0
      quote : Char? = nil

      while index < chars.size
        char = chars[index]

        if current_quote = quote
          output << char
          if char == current_quote
            if index + 1 < chars.size && chars[index + 1] == current_quote
              output << chars[index + 1]
              index += 1
            else
              quote = nil
            end
          elsif char == '\\' && index + 1 < chars.size
            output << chars[index + 1]
            index += 1
          end
        elsif char == '\'' || char == '"'
          quote = char
          output << char
        elsif char == '-' && index + 1 < chars.size && chars[index + 1] == '-'
          output << char << chars[index + 1]
          index += 1
          while index + 1 < chars.size && chars[index + 1] != '\n'
            output << chars[index + 1]
            index += 1
          end
        elsif char == '/' && index + 1 < chars.size && chars[index + 1] == '*'
          output << char << chars[index + 1]
          index += 1
          while index + 1 < chars.size
            index += 1
            output << chars[index]
            break if chars[index - 1] == '*' && chars[index] == '/'
          end
        elsif char == '?' && index + 1 < chars.size && chars[index + 1] == '?'
          # `??` is the escape for a literal `?` (PostgreSQL's JSONB `?`, `?|`
          # and `?&` operators), matching `Adapter::Base#ensure_clause_template`.
          output << '?'
          index += 1
        elsif char == '?'
          raise ArgumentError.new("Do not mix ? and numbered placeholders in one query clause") if dollar_style
          raise ArgumentError.new("Raw query placeholder count does not match bind values") if question_count >= values.size
          output << add_parameter(values[question_count])
          question_count += 1
        elsif char == '$' && index + 1 < chars.size && chars[index + 1].number?
          raise ArgumentError.new("Do not mix ? and numbered placeholders in one query clause") if question_count > 0
          dollar_style = true
          number_start = index + 1
          number_end = number_start
          while number_end < chars.size && chars[number_end].number?
            number_end += 1
          end
          parameter_index = chars[number_start...number_end].join.to_i
          unless parameter_index.in?(1..values.size)
            raise ArgumentError.new("Raw query placeholder count does not match bind values")
          end
          dollar_indices << parameter_index unless dollar_indices.includes?(parameter_index)
          token = dollar_tokens[parameter_index] ||= add_parameter(values[parameter_index - 1])
          output << token
          index = number_end - 1
        else
          output << char
        end

        index += 1
      end

      if dollar_style
        unless dollar_indices.size == values.size && values.size.times.all? { |number| dollar_indices.includes?(number + 1) }
          raise ArgumentError.new("Raw query placeholder count does not match bind values")
        end
      elsif question_count != values.size
        raise ArgumentError.new("Raw query placeholder count does not match bind values")
      end

      output.to_s
    end

    def order(use_default_order = true)
      return @order if @order

      order_fields = @query.order_fields

      if order_fields.none?
        if use_default_order && Grant.settings.implicit_order
          if @query.group_fields.any? && @query.group_fields.none? { |expression| expression[:field] == Model.primary_name }
            return nil
          end
          if @query.distinct? && (select_columns = @query.select_columns) && !select_columns.includes?(Model.primary_name)
            return nil
          end
          order_fields = default_order
          if !@query.join_clauses.empty?
            order_fields = order_fields.map do |expression|
              {field: qualify_join_field(expression[:field], Model.quote(Model.table_name)), direction: expression[:direction]}
            end
          end
        else
          return nil
        end
      end

      order_clauses = order_fields.map { |expression| render_order_term(expression) }

      @order = "ORDER BY #{order_clauses.join ", "}"
    end

    # Renders one ORDER BY term. A raw term is emitted as written; a column term
    # is qualified when joins are present and gets its direction and NULL
    # placement.
    protected def render_order_term(expression : NamedTuple(field: String, direction: Builder::Sort)) : String
      direction = expression[:direction]
      return expression[:field] if direction.raw?

      field = order_field_sql(expression[:field])
      add_aggregate_field field
      keyword = direction.sorts_descending? ? "DESC" : "ASC"
      case direction.nulls_placement
      when :first then nulls_ordering_sql(field, keyword, first: true)
      when :last  then nulls_ordering_sql(field, keyword, first: false)
      else             "#{field} #{keyword}"
      end
    end

    # `table.column` is checked against the model's table and the joined tables,
    # then quoted; anything else follows the ordinary join qualification.
    private def order_field_sql(field : String) : String
      parts = field.split('.')
      return qualify_join_field(field, Model.quote(Model.table_name)) unless parts.size == 2 && Grant::Query::SqlExpression.identifier?(field)

      unless parts[0] == Model.table_name || Grant::Query::JoinSupport.joins?(@query.join_clauses, parts[0])
        raise ArgumentError.new("Unknown query table #{parts[0].inspect} in ORDER BY for #{Model.name}")
      end
      "#{Model.quote(parts[0])}.#{Model.quote(parts[1])}"
    end

    # PostgreSQL and SQLite order NULLs natively; the MySQL assembler overrides
    # this because MySQL has no NULLS FIRST/LAST.
    protected def nulls_ordering_sql(field : String, keyword : String, first : Bool) : String
      "#{field} #{keyword} NULLS #{first ? "FIRST" : "LAST"}"
    end

    def group_by
      return @group_by if @group_by
      group_fields = @query.group_fields
      return nil if group_fields.none?
      group_clauses = group_fields.map do |expression|
        qualify_join_field(expression[:field], Model.quote(Model.table_name))
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
      field = qualify_join_field(Model.primary_name, Model.quote(Model.table_name))
      [{field: field, direction: Builder::Sort::Descending}]
    end

    def count : (Executor::MultiValue(Model, Int64) | Executor::Value(Model, Int64))
      if @query.distinct?
        distinct_rows_sql = build_sql do |s|
          s << "SELECT DISTINCT #{field_list}"
          s << from_clause
          s << joins
          s << where
          s << group_by
          s << having
          s << order(use_default_order: false) if @query.limit || @query.offset
          s << limit
          s << offset
        end
        sql = "#{select_prefix} COUNT(*) FROM (#{distinct_rows_sql}) AS grant_distinct_rows"
      elsif (@query.limit || @query.offset) && @query.group_fields.empty?
        # COUNT(*) yields one row, so a LIMIT/OFFSET on it would drop that row.
        # Count the rows the limited relation returns instead.
        limited_rows_sql = build_sql do |s|
          s << "SELECT 1"
          s << from_clause
          s << joins
          s << where
          s << having
          s << order(use_default_order: false)
          # SQLite and MySQL reject OFFSET without LIMIT; Int64::MAX is unbounded.
          s << (limit || "LIMIT #{Int64::MAX}")
          s << offset
        end
        sql = "#{select_prefix} COUNT(*) FROM (#{limited_rows_sql}) AS grant_limited_rows"
      else
        sql = build_sql do |s|
          s << "#{select_prefix} COUNT(*)"
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

      Executor::Value(Model, Int64).new sql, numbered_parameters, default: 0_i64
    end

    # Builds a grouped count that keeps every group key in the result.
    def grouped_count : Executor::Grouped(Model)
      group_expressions = @query.group_fields.map do |expression|
        qualify_join_field(expression[:field], Model.quote(Model.table_name))
      end

      sql = build_sql do |s|
        s << "#{select_prefix} #{group_expressions.join(", ")}, COUNT(*)"
        s << from_clause
        s << joins
        s << where
        s << group_by
        s << having
        s << order(use_default_order: false)
        s << limit
        s << offset
      end

      Executor::Grouped(Model).new(sql, group_expressions.size, numbered_parameters)
    end

    def first(n : Int32 = 1) : Executor::List(Model)
      sql = build_sql do |s|
        s << "#{select_keyword} #{field_list}"
        s << from_clause
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
      sql = if limited_or_joined_write?
              key_sql = write_target_subquery
              "DELETE FROM #{table_name} WHERE #{Model.quote(Model.primary_name)} IN (#{key_sql})"
            else
              build_sql do |s|
                s << "DELETE FROM #{table_name}"
                s << where
              end
            end

      log sql, numbered_parameters

      start_time = Time.instant
      begin
        adapter = Model.adapter
        result = adapter.open do |db|
          db.exec sql, args: adapter.normalize_bind_values(numbered_parameters)
        end

        duration = Time.instant - start_time
        Grant::Logs::SQL.info &.emit("Delete executed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          rows_affected: result.rows_affected
        )

        result
      rescue e
        duration = Time.instant - start_time
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
      if custom_statement = Model.custom_select_statement
        return custom_select(custom_statement)
      end

      sql = build_sql do |s|
        s << "#{select_keyword} #{field_list}"
        s << from_clause
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

    # Applies chainable query clauses to a model-declared SELECT by treating
    # the custom statement as a derived table. The alias matches the model's
    # table name so existing structured field qualification remains valid.
    private def custom_select(statement : String) : Executor::List(Model)
      statement = statement.rstrip
      statement = statement[0...-1].rstrip if statement.ends_with?(';')
      fields = if select_columns = @query.select_columns
                 select_columns.map { |field| Model.quote(field) }.join(", ")
               else
                 "*"
               end
      source = "(#{statement}) AS #{Model.quote(Model.table_name)}"

      sql = build_sql do |s|
        s << "#{select_keyword} #{fields} FROM #{source}"
        s << joins
        s << where
        s << group_by
        s << having
        s << order(use_default_order: false)
        s << limit
        s << offset
        s << lock
      end

      Executor::List(Model).new sql, numbered_parameters
    end

    # The adapter-specific keyword(s) that prefix a SELECT to obtain its query
    # plan. Overridden per adapter (SQLite uses `EXPLAIN QUERY PLAN`).
    def explain_keyword(analyze : Bool = false) : String
      "EXPLAIN"
    end

    # Builds the SELECT SQL for this query (without executing it), used as the
    # statement that `explain` wraps.
    def explain_select_sql : String
      build_sql do |s|
        s << "#{select_keyword} #{field_list}"
        s << from_clause
        s << joins
        s << where
        s << group_by
        s << having
        s << order
        s << limit
        s << offset
      end
    end

    # Runs the query through the adapter's EXPLAIN (optionally EXPLAIN ANALYZE)
    # and returns the plan as text.
    #
    # The result-set shape of EXPLAIN differs across databases, so every column
    # of every row is read generically (as `DB::Any`), stringified, and joined.
    # Degrades gracefully: if the adapter raises (e.g. ANALYZE unsupported), the
    # error message is returned as the plan text rather than propagating.
    def explain(analyze : Bool = false) : String
      sql = "#{explain_keyword(analyze)} #{explain_select_sql}"
      params = numbered_parameters

      begin
        rows = [] of String
        adapter = Model.adapter
        adapter.open do |db|
          db.query(sql, args: adapter.normalize_bind_values(params)) do |rs|
            rs.each do
              cells = [] of String
              rs.column_count.times do
                value = rs.read
                cells << (value.nil? ? "" : value.to_s)
              end
              rows << cells.join(" | ")
            end
          end
        end
        rows.join("\n")
      rescue e
        "EXPLAIN failed: #{e.message}"
      end
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
      set_parts = ["#{Model.quote("updated_at")} = #{add_parameter(time)}"]

      # Add any additional fields to touch
      fields.each do |field|
        set_parts << "#{Model.quote(field.to_s)} = #{add_parameter(time)}"
      end

      where_clause = if limited_or_joined_write?
                       "WHERE #{Model.quote(Model.primary_name)} IN (#{write_target_subquery})"
                     else
                       where
                     end
      sql = build_sql do |s|
        s << "UPDATE #{table_name}"
        s << "SET #{set_parts.join(", ")}"
        s << where_clause
      end

      log sql, numbered_parameters

      start_time = Time.instant
      begin
        adapter = Model.adapter
        rows_affected = adapter.open do |db|
          db.exec(sql, args: adapter.normalize_bind_values(numbered_parameters)).rows_affected
        end

        duration = Time.instant - start_time
        Grant::Logs::SQL.info &.emit("Touch all executed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          rows_affected: rows_affected,
          fields: fields.to_a.map { |f| f.to_s.as(String) }
        )

        rows_affected
      rescue e
        duration = Time.instant - start_time
        Grant::Logs::SQL.error &.emit("Touch all failed",
          sql: sql,
          model: Model.name,
          duration_ms: duration.total_milliseconds,
          error: e.message
        )
        raise e
      end
    end

    # Builds a parameterized UPDATE ... SET ... [WHERE ...] statement from an
    # ordered list of `{column, value}` assignments.
    #
    # Every value is routed through `add_parameter` so it is bound by the driver
    # (never interpolated), making this safe against SQL injection. SET
    # parameters are added before the WHERE clause is rendered so positional
    # placeholder numbering (PG `$1`, `$2`, ...) stays correct.
    #
    # Returns the SQL string; bound values are available via `numbered_parameters`.
    def update_all_sql(assignments : Array(Tuple(String, Grant::Columns::Type))) : String
      set_parts = assignments.map do |(column, value)|
        "#{Model.quote(column)} = #{add_parameter(value)}"
      end

      # Render WHERE after SET so its parameters follow the SET parameters.
      where_clause = if limited_or_joined_write?
                       "WHERE #{Model.quote(Model.primary_name)} IN (#{write_target_subquery})"
                     else
                       where
                     end

      build_sql do |s|
        s << "UPDATE #{table_name}"
        s << "SET #{set_parts.join(", ")}"
        s << where_clause
      end
    end

    # Builds an UPDATE for a developer-controlled SET fragment while preserving
    # any relation joins, order, limit, and offset.
    def update_all_fragment_sql(assignments : String) : String
      where_clause = if limited_or_joined_write?
                       "WHERE #{Model.quote(Model.primary_name)} IN (#{write_target_subquery})"
                     else
                       where
                     end

      build_sql do |s|
        s << "UPDATE #{table_name} SET #{assignments}"
        s << where_clause
      end
    end

    private def limited_or_joined_write? : Bool
      !@query.limit.nil? || !@query.offset.nil? || !@query.join_clauses.empty?
    end

    # The inner query selects the exact primary keys targeted by a bulk write.
    # The outer UPDATE/DELETE syntax works across PostgreSQL and SQLite.
    private def write_target_subquery : String
      subquery = build_sql do |s|
        s << "SELECT #{Model.quote(Model.primary_name)} FROM #{table_name}"
        s << joins
        s << where
        s << order(use_default_order: false)
        s << limit
        s << offset
      end

      # MySQL rejects LIMIT directly inside an IN subquery. A derived-table
      # layer makes the selected target keys legal for bounded bulk writes.
      if Model.adapter.mysql?
        "SELECT grant_write_targets.#{Model.quote(Model.primary_name)} FROM (#{subquery}) AS grant_write_targets"
      else
        subquery
      end
    end

    OPERATORS = {"eq": "=", "gteq": ">=", "lteq": "<=", "neq": "!=", "ltgt": "<>", "gt": ">", "lt": "<", "ngt": "!>", "nlt": "!<", "in": "IN", "nin": "NOT IN", "like": "LIKE", "nlike": "NOT LIKE"}

    def sql_operator(operator : Symbol) : String
      OPERATORS[operator.to_s]? || operator.to_s
    end
  end
end
