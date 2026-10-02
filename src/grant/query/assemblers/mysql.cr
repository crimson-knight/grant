# Query runner which finalizes a query and runs it.
# This will likely require adapter specific subclassing :[.
module Grant::Query::Assembler
  class Mysql(Model) < Base(Model)
    @placeholder = "?"

    def add_parameter(value : Grant::Columns::Type) : String
      value = value.to_s if value.is_a?(UUID)
      @numbered_parameters << value
      "?"
    end

    # MySQL has no NULLS FIRST/LAST, so an `ISNULL(column)` term goes first (1
    # for NULL): descending puts NULLs first, ascending puts them last.
    protected def nulls_ordering_sql(field : String, keyword : String, first : Bool) : String
      "ISNULL(#{field}) #{first ? "DESC" : "ASC"}, #{field} #{keyword}"
    end

    protected def text_cast_type : String
      "CHAR"
    end

    # Adding a double turns the DECIMAL result into a DOUBLE on every version.
    protected def double_cast_sql(expression : String) : String
      "(#{expression} + 0e0)"
    end

    # MySQL supports `EXPLAIN`; `EXPLAIN ANALYZE` is available on 8.0.18+. If the
    # server is older, `explain(analyze: true)` degrades gracefully (the base
    # `explain` rescues the error and returns its message).
    def explain_keyword(analyze : Bool = false) : String
      analyze ? "EXPLAIN ANALYZE" : "EXPLAIN"
    end

    # Generate SQL for pluck operation
    def pluck_sql(fields : Array(String)) : String
      select_fields = fields.map do |field|
        sql_field = pluck_field_sql(field)
        add_aggregate_field(sql_field)
        sql_field
      end.join(", ")

      build_sql do |s|
        s << with_clause
        s << "#{select_keyword} #{select_fields}"
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
  end
end
