module Grant::Aggregations
  module ClassMethods
    # Sum the values of a specific column
    def sum(column : Symbol | String) : Float64
      current_scope.sum(column)
    end

    # Calculate average of a specific column
    def avg(column : Symbol | String) : Float64?
      current_scope.avg(column)
    end

    # ActiveRecord-compatible name for `avg`.
    def average(column : Symbol | String) : Float64?
      avg(column)
    end

    # Find minimum value of a specific column
    def min(column : Symbol | String) : Grant::Columns::Type
      current_scope.min(column)
    end

    def minimum(column : Symbol | String) : Grant::Columns::Type
      min(column)
    end

    # Find maximum value of a specific column
    def max(column : Symbol | String) : Grant::Columns::Type
      current_scope.max(column)
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

    # Sum with query conditions
    def sum(column : Symbol | String) : Float64
      sql = build_sql do |s|
        s << "SELECT COALESCE(SUM(#{aggregate_field(column)}), 0)"
        s << "FROM #{table_name}"
        s << joins
        s << where
      end

      result = 0.0
      adapter = Model.adapter
      adapter.open do |db|
        value = db.scalar(sql, args: adapter.normalize_bind_values(numbered_parameters))
        result = value.to_s.to_f64 unless value.nil?
      end
      result
    end

    # Average with query conditions
    def avg(column : Symbol | String) : Float64?
      sql = build_sql do |s|
        s << "SELECT AVG(#{aggregate_field(column)})"
        s << "FROM #{table_name}"
        s << joins
        s << where
      end

      result = nil
      adapter = Model.adapter
      adapter.open do |db|
        value = db.scalar(sql, args: adapter.normalize_bind_values(numbered_parameters))
        str_value = value.to_s
        result = str_value.nil? || str_value == "NULL" ? nil : str_value.to_f64 unless value.nil?
      end
      result
    end

    # Min with query conditions
    def min(column : Symbol | String) : Grant::Columns::Type
      sql = build_sql do |s|
        s << "SELECT MIN(#{aggregate_field(column)})"
        s << "FROM #{table_name}"
        s << joins
        s << where
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

    # Max with query conditions
    def max(column : Symbol | String) : Grant::Columns::Type
      sql = build_sql do |s|
        s << "SELECT MAX(#{aggregate_field(column)})"
        s << "FROM #{table_name}"
        s << joins
        s << where
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
      reverse_order = @order_fields.map do |field|
        new_direction = field[:direction] == Sort::Ascending ? Sort::Descending : Sort::Ascending
        {field: field[:field], direction: new_direction}
      end

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

class Grant::Query::Builder(Model)
  def sum(column : Symbol | String) : Float64
    assembler.sum(column)
  end

  def avg(column : Symbol | String) : Float64?
    assembler.avg(column)
  end

  def average(column : Symbol | String) : Float64?
    avg(column)
  end

  def min(column : Symbol | String) : Grant::Columns::Type
    assembler.min(column)
  end

  def minimum(column : Symbol | String) : Grant::Columns::Type
    min(column)
  end

  def max(column : Symbol | String) : Grant::Columns::Type
    assembler.max(column)
  end

  def maximum(column : Symbol | String) : Grant::Columns::Type
    max(column)
  end
end
