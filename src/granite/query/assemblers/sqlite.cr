module Granite::Query::Assembler
  class Sqlite(Model) < Base(Model)
    @placeholder = "?"

    def add_parameter(value : Granite::Columns::Type) : String
      @numbered_parameters << value
      "?"
    end
    
    # Generate SQL for pluck operation
    def pluck_sql(fields : Array(String)) : String
      select_fields = fields.map { |f| add_aggregate_field(f); f }.join(", ")
      
      build_sql do |s|
        s << "SELECT #{select_fields}"
        s << "FROM #{table_name}"
        s << where
        s << group_by
        s << order
        s << limit
        s << offset
      end
    end
    
    # Generate SQL for insert_all operation
    def insert_all_sql(attributes : Array(Hash(String, Granite::Columns::Type)), 
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
    def upsert_all_sql(attributes : Array(Hash(String, Granite::Columns::Type)), 
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
      
      # SQLite uses INSERT OR REPLACE for upsert
      sql = "INSERT OR REPLACE INTO #{table_name} (#{column_list}) VALUES #{values_list}"
      
      # Note: SQLite's INSERT OR REPLACE is not exactly the same as PostgreSQL's
      # ON CONFLICT DO UPDATE. It will delete and re-insert the row, which can
      # affect foreign key constraints and triggers.
      # A more accurate implementation would use multiple statements or
      # the newer ON CONFLICT syntax in SQLite 3.24+
      
      if unique_by && !unique_by.empty? && update_only && !update_only.empty?
        # For SQLite 3.24+, we could use ON CONFLICT
        conflict_columns = unique_by.map(&.to_s).join(", ")
        
        # Determine which columns to update
        update_columns = update_only.map(&.to_s)
        
        # Build update assignments
        updates = update_columns.map do |col|
          "#{col} = excluded.#{col}"
        end
        
        sql = "INSERT INTO #{table_name} (#{column_list}) VALUES #{values_list}"
        sql += " ON CONFLICT(#{conflict_columns}) DO UPDATE SET "
        sql += updates.join(", ")
      end
      
      sql
    end
  end
end
