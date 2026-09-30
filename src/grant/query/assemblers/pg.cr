# Query runner which finalizes a query and runs it.
# This will likely require adapter specific subclassing :[.
module Grant::Query::Assembler
  class Pg(Model) < Base(Model)
    @placeholder = "?"

    def add_parameter(value : Grant::Columns::Type) : String
      @numbered_parameters << value
      "$#{@numbered_parameters.size}"
    end

    protected def select_field_sql(field : String) : String
      sql_field = super
      column_name = field.split('.').last

      if column_name.starts_with?("_serialized_")
        "#{sql_field}::TEXT AS #{Model.quote(column_name)}"
      else
        sql_field
      end
    end

    # PostgreSQL supports `EXPLAIN` and `EXPLAIN ANALYZE` (the latter executes
    # the query to produce real timing/row counts).
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
