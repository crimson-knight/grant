# Convenience Methods for Grant ORM
#
# Provides convenience methods for querying and manipulating data,
# including pluck, pick, in_batches, upsert_all, insert_all, and query annotations.
#
# ## Features
#
# - `pluck` - Extract one or more columns from records
# - `pick` - Extract columns from a single record
# - `in_batches` - Process records in batches
# - `upsert_all` - Bulk upsert (insert or update)
# - `insert_all` - Bulk insert with options
# - `annotate` - Add comments to queries for debugging
#
# ## Usage
#
# ```crystal
# # Pluck multiple columns
# User.where(active: true).pluck(:id, :name)
# # => [[1, "John"], [2, "Jane"]]
# 
# # Pick from first record
# User.pick(:id, :name)
# # => [1, "John"]
# 
# # Process in batches
# User.in_batches(of: 100) do |batch|
#   batch.update_all(processed: true)
# end
# 
# # Bulk upsert
# User.upsert_all([
#   {name: "John", email: "john@example.com"},
#   {name: "Jane", email: "jane@example.com"}
# ])
# 
# # Annotate queries
# User.where(active: true).annotate("Called from dashboard").select
# ```

module Granite::ConvenienceMethods(Model)
  # Extract values for specific columns
  def pluck(*fields : Symbol) : Array(Array(Granite::Columns::Type))
    field_names = fields.to_a.map(&.to_s)
    
    # Create assembler instance once to preserve parameters
    @_cached_assembler ||= begin
      case @db_type
      when Granite::Query::Builder::DbType::Pg
        Granite::Query::Assembler::Pg(Model).new(self)
      when Granite::Query::Builder::DbType::Mysql
        Granite::Query::Assembler::Mysql(Model).new(self)
      when Granite::Query::Builder::DbType::Sqlite
        Granite::Query::Assembler::Sqlite(Model).new(self)
      else
        raise "Unknown database type: #{@db_type}"
      end
    end
    
    sql = @_cached_assembler.not_nil!.pluck_sql(field_names)
    Granite::Query::Executor::Pluck(Model).new(sql, @_cached_assembler.not_nil!.numbered_parameters, field_names).run
  end
  
  # Extract values from the first record
  def pick(*fields : Symbol) : Array(Granite::Columns::Type)?
    limit(1).pluck(*fields).first?
  end
  
  # Process records in batches
  def in_batches(of batch_size : Int32 = 1000, start : Int64? = nil, finish : Int64? = nil, load : Bool = false, error_on_ignore : Bool = false, order : Symbol = :asc, &block : Array(Model) -> _)
    relation = self
    batch_order = order == :desc ? Granite::Query::Builder::Sort::Descending : Granite::Query::Builder::Sort::Ascending
    
    # Ensure we have a primary key order
    primary_key = Model.primary_name
    relation = relation.order({primary_key => batch_order == Granite::Query::Builder::Sort::Ascending ? :asc : :desc})
    
    # Apply start/finish constraints
    if start
      op = batch_order == Granite::Query::Builder::Sort::Ascending ? :gteq : :lteq
      relation = relation.where(primary_key, op, start.as(Granite::Columns::Type))
    end
    
    if finish
      op = batch_order == Granite::Query::Builder::Sort::Ascending ? :lteq : :gteq
      relation = relation.where(primary_key, op, finish.as(Granite::Columns::Type))
    end
    
    loop do
      batch_relation = relation.limit(batch_size)
      records = batch_relation.select
      
      break if records.empty?
      
      yield records
      
      break if records.size < batch_size
      
      # Get the last primary key value for the next batch
      last_record = records.last
      last_id = last_record.read_attribute(primary_key).as(Int64)
      
      # Update relation for next batch
      op = batch_order == Granite::Query::Builder::Sort::Ascending ? :gt : :lt
      # Update the where condition on the same relation
      relation = relation.where(primary_key, op, last_id)
    end
  end
  
  # Add annotation to queries
  def annotate(comment : String)
    @query_annotation = comment
    self
  end
  
  # Update query builder to include annotation
  def raw_sql
    sql = assembler.select.raw_sql
    if ann = @query_annotation
      "/* #{ann} */ #{sql}"
    else
      sql
    end
  end
end

# Class methods for bulk operations
module Granite::BulkOperations
  # Bulk insert records
  def insert_all(attributes : Array(Hash(String | Symbol, Granite::Columns::Type)), 
                 returning : Array(Symbol)? = nil,
                 unique_by : Array(Symbol)? = nil,
                 record_timestamps : Bool = true) : Array(self)
    
    return [] of self if attributes.empty?
    
    # Transform all keys to strings and ensure proper types
    string_attributes = attributes.map do |attrs|
      attrs.transform_keys(&.to_s).transform_values { |v| v.as(Granite::Columns::Type) }
    end
    
    # Add timestamps if needed
    if record_timestamps
      now = Time.utc.as(Granite::Columns::Type)
      string_attributes = string_attributes.map do |attrs|
        new_attrs = attrs.dup
        new_attrs["created_at"] ||= now
        new_attrs["updated_at"] ||= now
        new_attrs
      end
    end
    
    # Create a query builder to get assembler
    builder = __builder
    assembler = builder.assembler
    sql = assembler.insert_all_sql(
      attributes: string_attributes,
      returning: returning,
      unique_by: unique_by
    )
    
    records = [] of self
    
    mark_write_operation
    adapter.open do |db|
      db.query(sql, args: assembler.numbered_parameters) do |rs|
        rs.each do
          record = self.new
          # Populate record from result set if returning was specified
          if returning
            returning.each do |field|
              value = read_column_value(rs, field.to_s)
              record.write_attribute(field.to_s, value)
            end
          end
          records << record
        end
      end
    end
    
    records
  end
  
  # Bulk upsert records
  def upsert_all(attributes : Array(Hash(String | Symbol, Granite::Columns::Type)),
                 returning : Array(Symbol)? = nil,
                 unique_by : Array(Symbol)? = nil,
                 update_only : Array(Symbol)? = nil,
                 record_timestamps : Bool = true) : Array(self)
    
    return [] of self if attributes.empty?
    
    # Transform all keys to strings and ensure proper types
    string_attributes = attributes.map do |attrs|
      attrs.transform_keys(&.to_s).transform_values { |v| v.as(Granite::Columns::Type) }
    end
    
    # Add timestamps if needed
    if record_timestamps
      now = Time.utc.as(Granite::Columns::Type)
      string_attributes = string_attributes.map do |attrs|
        new_attrs = attrs.dup
        new_attrs["created_at"] ||= now
        new_attrs["updated_at"] = now
        new_attrs
      end
    end
    
    # Create a query builder to get assembler
    builder = __builder
    assembler = builder.assembler
    sql = assembler.upsert_all_sql(
      attributes: string_attributes,
      returning: returning,
      unique_by: unique_by,
      update_only: update_only
    )
    
    records = [] of self
    
    mark_write_operation
    adapter.open do |db|
      db.query(sql, args: assembler.numbered_parameters) do |rs|
        rs.each do
          record = self.new
          # Populate record from result set if returning was specified
          if returning
            returning.each do |field|
              value = read_column_value(rs, field.to_s)
              record.write_attribute(field.to_s, value)
            end
          end
          records << record
        end
      end
    end
    
    records
  end
  
  private def read_column_value(rs, column_name : String)
    column = column_for_attribute(column_name)
    return nil unless column
    
    case column.column_type.name
    when "String"
      rs.read(String?)
    when "Int32"
      rs.read(Int32?)
    when "Int64"
      rs.read(Int64?)
    when "Float32"
      rs.read(Float32?)
    when "Float64"
      rs.read(Float64?)
    when "Bool"
      rs.read(Bool?)
    when "Time"
      rs.read(Time?)
    else
      rs.read(String?)
    end
  end
end

# Include in query builder
class Granite::Query::Builder(Model)
  include Granite::ConvenienceMethods(Model)
  
  @query_annotation : String?
  @_cached_assembler : Granite::Query::Assembler::Base(Model)?
end

# Include in Base
abstract class Granite::Base
  extend Granite::BulkOperations
end