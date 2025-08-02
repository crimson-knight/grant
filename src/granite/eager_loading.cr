module Granite::EagerLoading
  macro included
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @loaded_associations = {} of String => Array(Granite::Base) | Granite::Base | Nil
    
    # Check if an association has been loaded
    def association_loaded?(name : String | Symbol)
      @loaded_associations.has_key?(name.to_s)
    end
    
    # Get loaded association data
    def get_loaded_association(name : String | Symbol)
      @loaded_associations[name.to_s]?
    end
    
    # Set loaded association data  
    def set_loaded_association(name : String | Symbol, data)
      @loaded_associations[name.to_s] = data
    end
    
    # Clear all loaded associations
    def clear_loaded_associations
      @loaded_associations.clear
    end
  end
  
  module ClassMethods
    def includes(*associations)
      query = get_query_builder
      query.includes(*associations)
      query
    end
    
    def includes(**nested_associations)
      query = get_query_builder
      nested_associations.each do |name, nested|
        query.includes({name => nested.is_a?(Array) ? nested : [nested]})
      end
      query
    end
    
    def preload(*associations)
      query = get_query_builder
      query.preload(*associations)
      query
    end
    
    def preload(**nested_associations)
      query = get_query_builder
      nested_associations.each do |name, nested|
        query.preload({name => nested.is_a?(Array) ? nested : [nested]})
      end
      query
    end
    
    def eager_load(*associations)
      query = get_query_builder
      query.eager_load(*associations)
      query
    end
    
    def eager_load(**nested_associations)
      query = get_query_builder
      nested_associations.each do |name, nested|
        query.eager_load({name => nested.is_a?(Array) ? nested : [nested]})
      end
      query
    end
    
    private def get_query_builder
      # Try to use current_scope if available (from Scoping module)
      if self.responds_to?(:current_scope)
        current_scope
      else
        # Fallback to creating a new query builder
        db_type = case adapter.class.to_s
                  when /Pg/
                    Granite::Query::Builder::DbType::Pg
                  when /Mysql/
                    Granite::Query::Builder::DbType::Mysql
                  else
                    Granite::Query::Builder::DbType::Sqlite
                  end
        Granite::Query::Builder(self).new(db_type)
      end
    end
  end
end