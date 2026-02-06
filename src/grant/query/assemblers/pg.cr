# Query runner which finalizes a query and runs it.
# This will likely require adapter specific subclassing :[.
module Grant::Query::Assembler
  class Pg(Model) < Base(Model)
    @placeholder = "?"

    def add_parameter(value : Grant::Columns::Type) : String
      @numbered_parameters << value
      "$#{@numbered_parameters.size}"
    end
    
    # Generate SQL for pluck operation
    def pluck_sql(fields : Array(String)) : String
      select_fields = fields.map { |f| add_aggregate_field(f); f }.join(", ")

      build_sql do |s|
        s << "#{select_keyword} #{select_fields}"
        s << "FROM #{table_name}"
        s << joins
        s << where
        s << group_by
        s << having
        s << order
        s << limit
        s << offset
      end
    end
    
    # Generate SQL for insert_all operation
    def insert_all_sql(attributes : Array(Hash(String, Grant::Columns::Type)), 
                       returning : Array(Symbol)?, 
                       unique_by : Array(Symbol)?) : String
      return "" if attributes.empty?
      
      # Get column names from first hash
      columns = attributes.first.keys
      column_list = columns.join(", ")
      
      # Build values list
      values_list = attributes.map do |attrs|
        values = columns.map do |col|
          add_parameter(attrs[col])
        end
        "(#{values.join(", ")})"
      end.join(", ")
      
      sql = "INSERT INTO #{table_name} (#{column_list}) VALUES #{values_list}"
      
      # Add ON CONFLICT for unique_by
      if unique_by && !unique_by.empty?
        conflict_columns = unique_by.map(&.to_s).join(", ")
        sql += " ON CONFLICT (#{conflict_columns}) DO NOTHING"
      end
      
      # Add RETURNING clause
      if returning && !returning.empty?
        returning_columns = returning.map(&.to_s).join(", ")
        sql += " RETURNING #{returning_columns}"
      end
      
      sql
    end
    
    # Generate SQL for upsert_all operation
    def upsert_all_sql(attributes : Array(Hash(String, Grant::Columns::Type)), 
                       returning : Array(Symbol)?, 
                       unique_by : Array(Symbol)?,
                       update_only : Array(Symbol)?) : String
      return "" if attributes.empty?
      
      # Get column names from first hash
      columns = attributes.first.keys
      column_list = columns.join(", ")
      
      # Build values list
      values_list = attributes.map do |attrs|
        values = columns.map do |col|
          add_parameter(attrs[col])
        end
        "(#{values.join(", ")})"
      end.join(", ")
      
      sql = "INSERT INTO #{table_name} (#{column_list}) VALUES #{values_list}"
      
      # Add ON CONFLICT clause
      conflict_columns = if unique_by && !unique_by.empty?
        unique_by.map(&.to_s).join(", ")
      else
        # Default to primary key
        Model.primary_name
      end
      
      sql += " ON CONFLICT (#{conflict_columns}) DO UPDATE SET "
      
      # Determine which columns to update
      update_columns = if update_only && !update_only.empty?
        update_only.map(&.to_s)
      else
        # Update all columns except primary key and unique_by columns
        excluded = [Model.primary_name]
        excluded += unique_by.map(&.to_s) if unique_by
        columns.reject { |col| excluded.includes?(col) }
      end
      
      # Build update assignments
      updates = update_columns.map do |col|
        "#{col} = EXCLUDED.#{col}"
      end
      
      sql += updates.join(", ")
      
      # Add RETURNING clause
      if returning && !returning.empty?
        returning_columns = returning.map(&.to_s).join(", ")
        sql += " RETURNING #{returning_columns}"
      end
      
      sql
    end
  end
end
