# FROM-source and WITH rendering. Both draw their bind values from this
# assembler's numbering, so a subquery's or CTE's `$n` come before the main
# query's and a nested SELECT never restarts at `$1`.
module Grant::Query::Assembler
  abstract class Base(Model)
    @with_sql : String?
    @with_rendered : Bool = false
    @from_sql : String?
    @from_rendered : Bool = false

    # Makes this assembler number and collect its binds in *params*, the array
    # of the statement it is nested in.
    #
    # :nodoc:
    def share_parameters(params : Array(Grant::Columns::Type)) : Nil
      @numbered_parameters = params
    end

    # Rewrites the `?` placeholders of the raw fragment *sql* to this
    # assembler's numbering and records *binds*.
    #
    # :nodoc:
    def bind_fragment(sql : String, binds : Array(Grant::Columns::Type)) : String
      bind_raw_statement(sql, binds)
    end

    # `WITH [RECURSIVE] "a" AS (...), "b" AS (...)`, or nil without CTEs. Built
    # once per statement, before any other clause, so its binds come first.
    def with_clause : String?
      return @with_sql if @with_rendered

      @with_rendered = true
      tables = @query.common_tables
      return nil if tables.empty?

      Grant::Query::CommonTableExpressions.ensure_supported!(Model.adapter)
      entries = tables.map { |table| "#{Model.quote(table.name)} AS (#{table.render.call(self)})" }
      keyword = tables.any?(&.recursive) ? "WITH RECURSIVE" : "WITH"
      @with_sql = "#{keyword} #{entries.join(", ")}"
    end

    # The source `from` set (`(SELECT ...) AS "users"`), or nil for the
    # model's own table. Built once per statement.
    def from_source_sql : String?
      return @from_sql if @from_rendered

      @from_rendered = true
      render = @query.from_render
      return nil unless render

      body = render.call(self)
      alias_name = @query.from_alias
      @from_sql = case @query.from_kind
                  when :subquery then "(#{body}) AS #{Model.quote(alias_name || Model.table_name)}"
                  else                alias_name ? "#{body} AS #{Model.quote(alias_name)}" : body
                  end
    end
  end
end
