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
    @predicate_renderer : Grant::Query::Assembler::PredicateRenderer?

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
        sql = "#{comment} #{sql}"
      end
      # Trailing tag comment from `Grant::QueryLogs` (no-op while it is off).
      Grant::QueryLogs.append(sql)
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

    # The renderer for this assembler's model, built once. It takes the model's
    # name, table and columns as plain values and its quoting as a proc, so
    # rendering is shared by every model (see `PredicateRenderer`). Quoting goes
    # through `Model.quote` when a column is rendered, as it did before the
    # renderer existed: building the renderer must not resolve the model's
    # adapter, which a sharded model only has inside a shard context.
    private def predicate_renderer : Grant::Query::Assembler::PredicateRenderer
      renderer = @predicate_renderer ||= Grant::Query::Assembler::PredicateRenderer.new(
        Model.name, Model.table_name, Model.fields,
        ->(name : String) : String { Model.quote(name) },
        ->(value : Grant::Columns::Type) : String { add_parameter(value) },
        ->(name : String) : Nil { add_aggregate_field(name); nil },
        @query.join_clauses)
      renderer.join_clauses = @query.join_clauses
      renderer.rendering_where_group = @rendering_where_group
      renderer
    end

    private def render_where_fields(fields : Array(Grant::Query::WhereField)) : String
      predicate_renderer.render_where_fields(fields)
    end

    private def structured_field_sql(field : String) : String
      predicate_renderer.structured_field_sql(field)
    end

    # Rewrites raw-clause placeholders to this assembler's local bind numbering
    # and rejects mismatched argument counts before the driver sees the SQL.
    private def bind_raw_statement(statement : String, values : Array(Grant::Columns::Type)) : String
      predicate_renderer.bind_raw_statement(statement, values)
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
      @lock ||= (@query.lock_sql(Model.adapter) if @query.locked?)
    end

    def log(*stuff)
    end

    def default_order
      field = qualify_join_field(Model.primary_name, Model.quote(Model.table_name))
      [{field: field, direction: Builder::Sort::Descending}]
    end

    def count : (Executor::MultiValue(Model, Int64) | Executor::Value(Model, Int64))
      # Rendered first so its binds lead; the wrapped forms put it outermost.
      with_sql = with_clause
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
        sql = [with_sql, "#{select_prefix} COUNT(*) FROM (#{distinct_rows_sql}) AS grant_distinct_rows"].compact.join(" ")
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
        sql = [with_sql, "#{select_prefix} COUNT(*) FROM (#{limited_rows_sql}) AS grant_limited_rows"].compact.join(" ")
      else
        sql = build_sql do |s|
          s << with_sql
          s << "#{select_prefix} COUNT(*)"
          s << from_clause
          s << joins
          s << where
          s << group_by
          s << having
          # An ungrouped COUNT(*) returns one row, so ORDER BY is meaningless,
          # and PostgreSQL rejects an ORDER BY column outside any GROUP BY.
          s << order(use_default_order: false) unless @query.group_fields.empty?
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
        s << with_clause
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
        s << with_clause
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
        result = adapter.open(sql, numbered_parameters, Model.name) do |db|
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
        s << with_clause
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
        s << with_clause
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
        s << with_clause
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
        adapter.open(sql, params, Model.name) do |db|
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
        s << with_clause
        s << "SELECT EXISTS(SELECT 1 "
        s << (from_source_sql ? from_clause : "FROM #{table_name} ")
        s << joins
        s << where
        s << ")"
      end

      Executor::Value(Model, Bool).new sql, numbered_parameters, default: false
    end

    def touch_all(fields : Tuple, time : Time) : Int64
      # The update timestamp columns the model declares (`updated_at`,
      # `updated_on`), `updated_at` when it declares none; values follow the
      # same stamping rules as a save (date-only `*_on`, `precision:`).
      precision = Model.timestamp_precision
      update_columns = Model.update_timestamp_columns
      update_columns = ["updated_at"] if update_columns.empty?
      set_parts = update_columns.map do |column_name|
        "#{Model.quote(column_name)} = #{add_parameter(Grant::Timestamps.stamp(column_name, time, precision))}"
      end

      # Add any additional fields to touch
      fields.each do |field|
        next if update_columns.includes?(field.to_s)
        set_parts << "#{Model.quote(field.to_s)} = #{add_parameter(Grant::Timestamps.stamp(field.to_s, time, precision))}"
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
        rows_affected = adapter.open(sql, numbered_parameters, Model.name) do |db|
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

    def sql_operator(operator : Symbol) : String
      Grant::Query::Assembler::PredicateRenderer::OPERATORS[operator.to_s]? || operator.to_s
    end
  end
end
