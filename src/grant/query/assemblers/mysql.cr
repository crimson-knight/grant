# Query runner which finalizes a query and runs it.
# This will likely require adapter specific subclassing :[.
module Grant::Query::Assembler
  class Mysql(Model) < Base(Model)
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
      
      # MySQL uses INSERT IGNORE for conflict handling
      if unique_by && !unique_by.empty?
        sql = "INSERT IGNORE INTO #{table_name} (#{column_list}) VALUES #{values_list}"
      end
      
      # MySQL doesn't support RETURNING clause
      # Would need to use LAST_INSERT_ID() or similar
      
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
      
      # MySQL uses ON DUPLICATE KEY UPDATE
      sql += " ON DUPLICATE KEY UPDATE "
      
      # Determine which columns to update
      update_columns = if update_only && !update_only.empty?
        update_only.map(&.to_s)
      else
        # Update all columns except primary key
        excluded = [Model.primary_name]
        excluded += unique_by.map(&.to_s) if unique_by
        columns.reject { |col| excluded.includes?(col) }
      end
      
      # Build update assignments
      updates = update_columns.map do |col|
        "#{col} = VALUES(#{col})"
      end
      
      sql += updates.join(", ")
      
      sql
    end
  end
end
