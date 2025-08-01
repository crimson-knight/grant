require "./composite_primary_key/transactions"
require "./composite_primary_key/validation"

module Granite::CompositePrimaryKey
  # Stores composite primary key configuration
  struct CompositeKey
    property columns : Array(Symbol)
    
    def initialize(@columns : Array(Symbol))
      raise "Composite key must have at least 2 columns" if @columns.size < 2
    end
    
    # Generate a unique key string from values
    def key_for(values : Array) : String
      raise "Values count (#{values.size}) doesn't match columns count (#{@columns.size})" if values.size != @columns.size
      
      @columns.zip(values).map { |col, val| "#{col}=#{val}" }.join(":")
    end
    
    # Extract values from a model instance
    def values_for(model : Granite::Base) : Array
      @columns.map { |col| model.read_attribute(col.to_s) }
    end
    
    # Build WHERE clause for composite key
    def where_clause : String
      @columns.map { |col| "#{col} = ?" }.join(" AND ")
    end
    
    # Build named tuple from hash/named tuple input
    def build_key_tuple(**values) : NamedTuple
      # Verify all key columns are present
      @columns.each do |col|
        raise "Missing composite key column: #{col}" unless values.has_key?(col)
      end
      
      values
    end
  end
  
  macro included
    include Granite::CompositePrimaryKey::Transactions
    include Granite::CompositePrimaryKey::Validation
    
    class_property composite_key : CompositeKey?
    
    # Override primary_name to handle composite keys
    def self.primary_name
      if ck = composite_key
        # Return first column for backward compatibility
        ck.columns.first.to_s
      else
        # Use empty string as fallback - the actual primary key
        # will be handled by Granite::Tables module
        ""
      end
    end
    
    # Check if model uses composite primary key
    def self.composite_primary_key? : Bool
      !composite_key.nil?
    end
    
    # Get all primary key columns when using composite key DSL
    def self.composite_primary_key_columns : Array(Symbol)
      composite_key.try(&.columns) || [] of Symbol
    end
  end
  
  # DSL for defining composite primary keys
  macro composite_primary_key(*columns)
    # Simply store the composite key configuration
    # Validation will happen at runtime when CompositeKey is initialized
    self.composite_key = Granite::CompositePrimaryKey::CompositeKey.new(
      [{% for col in columns %}:{{col.id}}, {% end %}] of Symbol
    )
  end
  
  # Find by composite key
  def self.find(**keys)
    # Check if we're using composite primary key
    return previous_def unless composite_primary_key?
    
    ck = composite_key.not_nil!
    key_tuple = ck.build_key_tuple(**keys)
    
    # Build WHERE clause
    where_clause = ck.columns.map { |col| "#{quote(col.to_s)} = ?" }.join(" AND ")
    values = ck.columns.map { |col| key_tuple[col] }
    
    # Execute query
    all(where_clause, values).first
  end
  
  # Find by composite key, raises if not found
  def self.find!(**keys)
    find(**keys) || raise Granite::Querying::NotFound.new("No #{name} found with keys: #{keys}")
  end
  
  # Check existence by composite key
  def self.exists?(**keys) : Bool
    # Check if we're using composite primary key
    return previous_def unless composite_primary_key?
    
    ck = composite_key.not_nil!
    key_tuple = ck.build_key_tuple(**keys)
    
    # Build WHERE clause
    where_clause = ck.columns.map { |col| "#{quote(col.to_s)} = ?" }.join(" AND ")
    values = ck.columns.map { |col| key_tuple[col] }
    
    # Use adapter's exists? method
    adapter.exists?(table_name, where_clause, values)
  end
  
  # Instance methods
  
  # Get composite key values as hash
  def composite_key_values
    return nil unless self.class.composite_primary_key?
    
    ck = self.class.composite_key.not_nil!
    values = {} of Symbol => Granite::Columns::Type
    
    ck.columns.each do |col|
      values[col] = read_attribute(col.to_s)
    end
    
    values
  end
  
  # Check if this is a new record (all key parts must be set)
  def new_record? : Bool
    # Check if we're using composite primary key
    return previous_def unless self.class.composite_primary_key?
    
    # Use the @new_record flag which is managed by Granite::Base
    # This is set to true by default and false after save
    @new_record
  end
  
  # Reload from database using composite key
  def reload
    # Check if we're using composite primary key
    return previous_def unless self.class.composite_primary_key?
    
    key_values = composite_key_values
    return self if key_values.nil?
    
    # Find using composite key
    if found = self.class.find(**key_values)
      # Copy attributes from found instance
      found.to_h.each do |key, value|
        write_attribute(key, value)
      end
      @new_record = false
    end
    
    self
  end
end