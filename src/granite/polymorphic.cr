# Polymorphic associations support for Grant ORM
# 
# This module provides support for polymorphic associations, allowing a model to belong to
# more than one other model on a single association.
#
# Example:
# ```crystal
# class Comment < Granite::Base
#   # Creates imageable_id and imageable_type columns
#   belongs_to :imageable, polymorphic: true
# end
#
# class Post < Granite::Base
#   has_many :comments, as: :imageable
# end
#
# class Photo < Granite::Base
#   has_many :comments, as: :imageable
# end
# ```
module Granite::Polymorphic
  # Storage for polymorphic type mappings
  class_property polymorphic_type_map = {} of String => Granite::Base.class

  # Register a model class for polymorphic resolution
  def self.register_type(name : String, klass : Granite::Base.class)
    polymorphic_type_map[name] = klass
  end

  # Resolve a polymorphic type string to a class
  def self.resolve_type(name : String)
    polymorphic_type_map[name]?
  end

  # Extends the belongs_to macro to support polymorphic associations
  macro belongs_to_polymorphic(name, **options)
    # Extract the type column name
    {% type_column = options[:type_column] || name.id.stringify + "_type" %}
    {% foreign_key = options[:foreign_key] || name.id.stringify + "_id" %}
    {% primary_key = options[:primary_key] || "id" %}
    
    # Define the foreign key column
    column {{foreign_key.id}} : Int64?
    
    # Define the type column
    column {{type_column.id}} : String?
    
    # Define getter method
    def {{name.id}}
      return nil unless (type_value = @{{type_column.id}}) && (id_value = @{{foreign_key.id}})
      
      # Resolve the class from the type string
      klass = Granite::Polymorphic.resolve_type(type_value)
      return nil unless klass
      
      # Find the associated record
      klass.find(id_value)
    rescue Granite::Querying::NotFound
      nil
    end
    
    # Define setter method
    def {{name.id}}=(record)
      if record.nil?
        @{{foreign_key.id}} = nil
        @{{type_column.id}} = nil
      else
        @{{foreign_key.id}} = record.primary_key_value.as(Int64?)
        @{{type_column.id}} = record.class.name
      end
    end
    
    # Store association metadata
    class_getter _{{name.id}}_association_meta = {
      type: :belongs_to,
      polymorphic: true,
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}},
      primary_key: {{primary_key.id.stringify}}
    }
  end
  
  # Extends has_many to support polymorphic associations
  macro has_many_polymorphic(name, poly_as, **options)
    {% foreign_key = options[:foreign_key] || (poly_as.id.stringify + "_id") %}
    {% type_column = options[:type_column] || (poly_as.id.stringify + "_type") %}
    {% if name.is_a? TypeDeclaration %}
      {% method_name = name.var %}
      {% class_name = name.type %}
    {% else %}
      {% method_name = name.id %}
      {% class_name = options[:class_name] || name.id.stringify.camelcase %}
    {% end %}
    
    def {{method_name.id}}
      {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
    end
    
    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_many,
      polymorphic_as: {{poly_as.id.stringify}},
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}}
    }
  end
  
  # Extends has_one to support polymorphic associations
  macro has_one_polymorphic(name, poly_as, **options)
    {% foreign_key = options[:foreign_key] || (poly_as.id.stringify + "_id") %}
    {% type_column = options[:type_column] || (poly_as.id.stringify + "_type") %}
    {% if name.is_a? TypeDeclaration %}
      {% method_name = name.var %}
      {% class_name = name.type %}
    {% else %}
      {% method_name = name.id %}
      {% class_name = options[:class_name] || name.id.camelcase %}
    {% end %}
    
    def {{method_name.id}} : {{class_name.id}}?
      {{class_name.id}}.find_by({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
    end
    
    def {{method_name.id}}! : {{class_name.id}}
      {{class_name.id}}.find_by!({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
    end
    
    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_one,
      polymorphic_as: {{poly_as.id.stringify}},
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}}
    }
  end
  
  # Macro to auto-register a model for polymorphic associations
  macro register_polymorphic_type
    Granite::Polymorphic.register_type(self.name, self)
  end
end