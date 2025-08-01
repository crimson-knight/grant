module Granite::Scoping
  macro included
    macro inherited
      # Flag to track if we're in unscoped mode
      class_property? _unscoped : Bool = false
    end
  end
  
  # Define a named scope
  macro scope(name, body)
    def self.{{name.id}}
      query = current_scope
      {{body}}.call(query)
    end
  end
  
  # Define a default scope
  macro default_scope(&block)
    class_getter? _has_default_scope : Bool = true
    
    def self.apply_default_scope(query : Granite::Query::Builder({{ @type }}))
      query.{{block.body}}
    end
  end
  
  module ClassMethods
    
    # Get the current scope (with default scope applied unless unscoped)
    def current_scope
      db_type = case adapter.class.to_s
                when "Granite::Adapter::Pg"
                  Granite::Query::Builder::DbType::Pg
                when "Granite::Adapter::Mysql"
                  Granite::Query::Builder::DbType::Mysql
                else
                  Granite::Query::Builder::DbType::Sqlite
                end
      
      query = Granite::Query::Builder(self).new(db_type)
      
      # Apply default scope unless we're in unscoped mode
      # TODO: This needs a better solution - currently disabled
      # if !_unscoped? && self.responds_to?(:apply_default_scope)
      #   query = apply_default_scope(query)
      # end
      
      query
    end
    
    # Execute a block without the default scope
    def unscoped
      old_unscoped = _unscoped?
      self._unscoped = true
      
      db_type = case adapter.class.to_s
                when "Granite::Adapter::Pg"
                  Granite::Query::Builder::DbType::Pg
                when "Granite::Adapter::Mysql"
                  Granite::Query::Builder::DbType::Mysql
                else
                  Granite::Query::Builder::DbType::Sqlite
                end
      
      query = Granite::Query::Builder(self).new(db_type)
      
      if block_given?
        begin
          yield query
        ensure
          self._unscoped = old_unscoped
        end
      else
        query
      end
    end
    
    # Merge scopes together
    def merge(other_scope : Granite::Query::Builder)
      current = current_scope
      
      # Merge where conditions
      other_scope.where_fields.each do |field|
        current.where_fields << field
      end
      
      # Merge order fields
      other_scope.order_fields.each do |field|
        current.order_fields << field
      end
      
      # Merge group fields
      other_scope.group_fields.each do |field|
        current.group_fields << field
      end
      
      # Use the most restrictive limit
      if other_limit = other_scope.limit
        if current_limit = current.limit
          current.limit(Math.min(current_limit, other_limit))
        else
          current.limit(other_limit)
        end
      end
      
      # Use the largest offset
      if other_offset = other_scope.offset
        if current_offset = current.offset
          current.offset(Math.max(current_offset, other_offset))
        else
          current.offset(other_offset)
        end
      end
      
      current
    end
  end
  
  # Allow extending query chains with custom methods
  macro extending(&block)
    class QueryExtension < Granite::Query::Builder(\{{@type}})
      {{block.body}}
    end
    
    def self.extending
      QueryExtension.new(adapter.database_type)
    end
  end
  
  # Override query methods to use current_scope
  macro override_query_method(method_name)
    def self.{{method_name.id}}(*args, **kwargs)
      current_scope.{{method_name.id}}(*args, **kwargs)
    end
    
    def self.{{method_name.id}}(*args, **kwargs, &block)
      current_scope.{{method_name.id}}(*args, **kwargs) do |*yield_args|
        yield *yield_args
      end
    end
  end
  
  # Override common query methods to respect default scope
  override_query_method where
  override_query_method order
  override_query_method group_by
  override_query_method limit
  override_query_method offset
  override_query_method includes
  override_query_method preload
  override_query_method eager_load
  
  # Override all to respect default scope
  def self.all
    current_scope.select
  end
  
  # Override find to respect default scope
  def self.find(id)
    current_scope.find(id)
  end
  
  # Override find! to respect default scope
  def self.find!(id)
    current_scope.find!(id)
  end
end