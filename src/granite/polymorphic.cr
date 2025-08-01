# Polymorphic associations support for Grant ORM
# 
# This module provides support for polymorphic associations, allowing a model to belong to
# more than one other model on a single association.
#
# Example:
# ```crystal
# class Comment < Granite::Base
#   # Creates commentable_id and commentable_type columns
#   belongs_to :commentable, polymorphic: true
# end
#
# class Post < Granite::Base
#   has_many :comments, as: :commentable
# end
#
# class Photo < Granite::Base
#   has_many :comments, as: :commentable
# end
# ```
module Granite::Polymorphic
  # Compile-time storage for registered types
  REGISTERED_TYPES = {} of String => ASTNode
  
  # Register a model class for polymorphic resolution at compile time
  macro register_polymorphic_type(name, klass)
    {% REGISTERED_TYPES[name] = klass %}
  end
  
  # Generate the polymorphic loader after all types are registered
  macro finished
    # Load a polymorphic association by type name and id
    def self.load_polymorphic(type_name : String, id : Int64) : Granite::Base?
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {{klass}}.find(id)
      {% end %}
      else
        nil
      end
    end
    
    # Load polymorphic with find! semantics
    def self.load_polymorphic!(type_name : String, id : Int64) : Granite::Base
      load_polymorphic(type_name, id) || raise Granite::Querying::NotFound.new("No #{type_name} found with id #{id}")
    end
    
    # Check if a type is registered
    def self.registered_type?(type_name : String) : Bool
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        true
      {% end %}
      else
        false
      end
    end
  end
  
  # Proxy object for lazy loading polymorphic associations
  struct PolymorphicProxy
    getter type : String?
    getter id : Int64?
    
    def initialize(@type : String?, @id : Int64?)
    end
    
    # Load the associated record
    def load : Granite::Base?
      return nil unless @type && @id
      Granite::Polymorphic.load_polymorphic(@type.not_nil!, @id.not_nil!)
    end
    
    # Load with find! semantics
    def load! : Granite::Base
      raise Granite::Querying::NotFound.new("Polymorphic association not set") unless @type && @id
      Granite::Polymorphic.load_polymorphic!(@type.not_nil!, @id.not_nil!)
    end
    
    # Check if association is present
    def present? : Bool
      !@type.nil? && !@id.nil?
    end
    
    # Reload the association
    def reload : Granite::Base?
      load
    end
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
    
    # Define proxy getter
    def {{name.id}}_proxy : Granite::Polymorphic::PolymorphicProxy
      Granite::Polymorphic::PolymorphicProxy.new(@{{type_column.id}}, @{{foreign_key.id}})
    end
    
    # Define getter method
    def {{name.id}} : Granite::Base?
      {{name.id}}_proxy.load
    end
    
    # Define bang getter
    def {{name.id}}! : Granite::Base
      {{name.id}}_proxy.load!
    end
    
    # Define setter method
    def {{name.id}}=(record : Granite::Base?)
      if record.nil?
        @{{foreign_key.id}} = nil
        @{{type_column.id}} = nil
      else
        # Get primary key value and ensure it's Int64
        pk_value = record.primary_key_value
        @{{foreign_key.id}} = case pk_value
                              when Int64
                                pk_value
                              when Int32
                                pk_value.to_i64
                              else
                                raise "Polymorphic associations require numeric primary keys, got #{pk_value.class}"
                              end
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
    
    # Handle optional validation
    {% unless options[:optional] %}
      validate "{{name.id}} must be present" do |instance|
        !instance.{{foreign_key.id}}.nil? && !instance.{{type_column.id}}.nil?
      end
    {% end %}
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
    
    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        before_destroy do
          {{method_name.id}}.each(&.destroy)
        end
      {% elsif options[:dependent] == :nullify %}
        before_destroy do
          {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
            .update_all({{foreign_key.id}}: nil, {{type_column.id}}: nil)
        end
      {% end %}
    {% end %}
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
    
    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        before_destroy do
          {{method_name.id}}.try(&.destroy)
        end
      {% elsif options[:dependent] == :nullify %}
        before_destroy do
          {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
            .update_all({{foreign_key.id}}: nil, {{type_column.id}}: nil)
        end
      {% end %}
    {% end %}
  end
  
  # Macro to auto-register a model for polymorphic associations
  macro register_polymorphic_type
    Granite::Polymorphic.register_polymorphic_type({{@type.name.stringify}}, {{@type}})
  end
end