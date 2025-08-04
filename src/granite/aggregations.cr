module Granite::Aggregations
  module ClassMethods
    # Sum the values of a specific column
    def sum(column : Symbol | String) : Float64
      sql = "SELECT COALESCE(SUM(#{quote(column.to_s)}), 0) FROM #{quoted_table_name}"
      scalar(sql, &.to_s.to_f64)
    end
    
    # Calculate average of a specific column
    def avg(column : Symbol | String) : Float64?
      sql = "SELECT AVG(#{quote(column.to_s)}) FROM #{quoted_table_name}"
      result = scalar(sql, &.to_s)
      result.nil? || result == "NULL" ? nil : result.to_f64
    end
    
    # Find minimum value of a specific column
    def min(column : Symbol | String) : Granite::Columns::Type
      sql = "SELECT MIN(#{quote(column.to_s)}) FROM #{quoted_table_name}"
      result = nil
      query(sql) do |rs|
        if rs.move_next
          result = rs.read(Granite::Columns::Type)
        end
      end
      result
    end
    
    # Find maximum value of a specific column
    def max(column : Symbol | String) : Granite::Columns::Type
      sql = "SELECT MAX(#{quote(column.to_s)}) FROM #{quoted_table_name}"
      result = nil
      query(sql) do |rs|
        if rs.move_next
          result = rs.read(Granite::Columns::Type)
        end
      end
      result
    end
    
    # Pluck values from a specific column
    def pluck(column : Symbol | String) : Array(Granite::Columns::Type)
      results = [] of Granite::Columns::Type
      sql = "SELECT #{quote(column.to_s)} FROM #{quoted_table_name}"
      
      query(sql) do |rs|
        rs.each do
          value = rs.read(Granite::Columns::Type)
          results << value unless value.nil?
        end
      end
      
      results
    end
    
    # Pick the first value from a specific column
    def pick(column : Symbol | String) : Granite::Columns::Type?
      sql = "SELECT #{quote(column.to_s)} FROM #{quoted_table_name} LIMIT 1"
      
      result = nil
      query(sql) do |rs|
        if rs.move_next
          result = rs.read(Granite::Columns::Type)
        end
      end
      
      result
    end
    
    # Get the last record
    def last : self?
      sql = "SELECT #{fields.join(", ")} FROM #{quoted_table_name} ORDER BY #{quote(primary_name)} DESC LIMIT 1"
      
      result = nil
      adapter.select(select_container, sql, [] of Granite::Columns::Type) do |rs|
        if rs.move_next
          result = from_rs(rs)
        end
      end
      
      result
    end
    
    # Get the last record, raise if not found
    def last! : self
      last || raise NotFound.new("No #{{{@type.name.stringify}}} found with last")
    end
  end
  
  # Module for query builder aggregation methods
  module QueryMethods
    # Sum with query conditions
    def sum(column : Symbol | String) : Float64
      sql = build_sql do |s|
        s << "SELECT COALESCE(SUM(#{Model.quote(column.to_s)}), 0)"
        s << "FROM #{table_name}"
        s << where
      end
      
      result = 0.0
      Model.adapter.open do |db|
        db.scalar(sql, args: numbered_parameters) do |value|
          result = value.to_s.to_f64
        end
      end
      result
    end
    
    # Average with query conditions
    def avg(column : Symbol | String) : Float64?
      sql = build_sql do |s|
        s << "SELECT AVG(#{Model.quote(column.to_s)})"
        s << "FROM #{table_name}"
        s << where
      end
      
      result = nil
      Model.adapter.open do |db|
        db.scalar(sql, args: numbered_parameters) do |value|
          str_value = value.to_s
          result = str_value.nil? || str_value == "NULL" ? nil : str_value.to_f64
        end
      end
      result
    end
    
    # Min with query conditions
    def min(column : Symbol | String) : Granite::Columns::Type
      sql = build_sql do |s|
        s << "SELECT MIN(#{Model.quote(column.to_s)})"
        s << "FROM #{table_name}"
        s << where
      end
      
      result = nil
      Model.adapter.open do |db|
        db.query(sql, args: numbered_parameters) do |rs|
          if rs.move_next
            result = rs.read(Granite::Columns::Type)
          end
        end
      end
      result
    end
    
    # Max with query conditions
    def max(column : Symbol | String) : Granite::Columns::Type
      sql = build_sql do |s|
        s << "SELECT MAX(#{Model.quote(column.to_s)})"
        s << "FROM #{table_name}"
        s << where
      end
      
      result = nil
      Model.adapter.open do |db|
        db.query(sql, args: numbered_parameters) do |rs|
          if rs.move_next
            result = rs.read(Granite::Columns::Type)
          end
        end
      end
      result
    end
    
    # Pluck with query conditions
    def pluck(column : Symbol | String) : Array(Granite::Columns::Type)
      results = [] of Granite::Columns::Type
      sql = build_sql do |s|
        s << "SELECT #{Model.quote(column.to_s)}"
        s << "FROM #{table_name}"
        s << where
        s << order
        s << limit
        s << offset
      end
      
      Model.adapter.open do |db|
        db.query(sql, args: numbered_parameters) do |rs|
          rs.each do
            value = rs.read(Granite::Columns::Type)
            results << value unless value.nil?
          end
        end
      end
      
      results
    end
    
    # Pick with query conditions
    def pick(column : Symbol | String) : Granite::Columns::Type?
      sql = build_sql do |s|
        s << "SELECT #{Model.quote(column.to_s)}"
        s << "FROM #{table_name}"
        s << where
        s << order
        s << "LIMIT 1"
      end
      
      result = nil
      Model.adapter.open do |db|
        db.query(sql, args: numbered_parameters) do |rs|
          if rs.move_next
            result = rs.read(Granite::Columns::Type)
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
      last || raise Granite::Querying::NotFound.new("No record found")
    end
    
    # Update all matching records
    def update(**args) : Int64
      return 0_i64 if args.empty?
      
      Model.mark_write_operation
      
      set_parts = [] of String
      values = [] of Granite::Columns::Type
      
      args.each do |key, value|
        set_parts << "#{Model.quote(key.to_s)} = ?"
        values << value
      end
      
      # Add updated_at if model has it
      {% if Model.instance_vars.select { |ivar| ivar.annotation(Granite::Column) && ivar.name == "updated_at" }.size > 0 %}
        set_parts << "#{Model.quote("updated_at")} = ?"
        values << Time.local(Granite.settings.default_timezone).at_beginning_of_second
      {% end %}
      
      sql = build_sql do |s|
        s << "UPDATE #{table_name}"
        s << "SET #{set_parts.join(", ")}"
        s << where
      end
      
      # Append where parameters after set values
      values.concat(numbered_parameters)
      
      Model.adapter.open do |db|
        db.exec(sql, args: values).rows_affected
      end
    end
  end
end