module Grant::Query::Assembler
  class Sqlite(Model) < Base(Model)
    @placeholder = "?"

    def add_parameter(value : Grant::Columns::Type) : String
      @numbered_parameters << value
      "?"
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
      
      # SQLite supports ON CONFLICT for unique constraints
      if unique_by && !unique_by.empty?
        conflict_columns = unique_by.map(&.to_s).join(", ")
        sql = "INSERT OR IGNORE INTO #{table_name} (#{column_list}) VALUES #{values_list}"
      end
      
      # SQLite doesn't support RETURNING in the same way
      # Would need to handle this differently in the caller
      
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
      
      # SQLite 3.24+ supports proper ON CONFLICT syntax
      sql = "INSERT INTO #{table_name} (#{column_list}) VALUES #{values_list}"
      
      if unique_by && !unique_by.empty?
        conflict_columns = unique_by.map(&.to_s).join(", ")
        
        # Determine which columns to update
        update_columns = if update_only && !update_only.empty?
          update_only.map(&.to_s)
        else
          # Update all columns except primary key and unique columns
          excluded = [Model.primary_name]
          excluded += unique_by.map(&.to_s) if unique_by
          columns.reject { |col| excluded.includes?(col) }
        end
        
        if update_columns.empty?
          # If no columns to update, use DO NOTHING
          sql += " ON CONFLICT(#{conflict_columns}) DO NOTHING"
        else
          # Build update assignments
          updates = update_columns.map do |col|
            "#{col} = excluded.#{col}"
          end
          
          sql += " ON CONFLICT(#{conflict_columns}) DO UPDATE SET "
          sql += updates.join(", ")
        end
      end
      
      # Note: SQLite doesn't support RETURNING clause in the same way as PostgreSQL
      # This would need to be handled differently if returning is requested
      
      sql
    end
  end
end
