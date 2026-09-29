module Grant::Query::Assembler
  class Sqlite(Model) < Base(Model)
    @placeholder = "?"

    def add_parameter(value : Grant::Columns::Type) : String
      @numbered_parameters << value
      "?"
    end

    # SQLite exposes the human-readable plan via `EXPLAIN QUERY PLAN`. The bare
    # `EXPLAIN` form emits VDBE bytecode, which is rarely useful; SQLite has no
    # PG-style `ANALYZE`, so the keyword is the same regardless of *analyze*.
    def explain_keyword(analyze : Bool = false) : String
      "EXPLAIN QUERY PLAN"
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
