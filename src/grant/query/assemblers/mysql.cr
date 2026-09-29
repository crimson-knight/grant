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
