module Granite::EagerLoading
  macro included
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
      query = Granite::Query::Builder(self).new
      query.includes(*associations)
      query
    end
    
    def preload(*associations)
      query = Granite::Query::Builder(self).new
      query.preload(*associations)
      query
    end
    
    def eager_load(*associations)
      query = Granite::Query::Builder(self).new
      query.eager_load(*associations)
      query
    end
  end
end