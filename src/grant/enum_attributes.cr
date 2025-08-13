# Enum Attributes for Grant ORM
#
# Provides Rails-style enum attributes with helper methods for Crystal enums.
# 
# Example:
# ```crystal
# class Post < Grant::Base
#   enum Status
#     Draft
#     Published
#     Archived
#   end
#   
#   enum_attribute status : Status = :draft
# end
# 
# post = Post.new
# post.draft?      # => true
# post.published?  # => false
# post.published!  # => sets status to published
# post.status      # => Post::Status::Published
# ```

module Grant::EnumAttributes
  # Main macro for defining enum attributes with helper methods
  macro enum_attribute(decl, **options)
    {% 
      # Parse the declaration
      if decl.is_a?(TypeDeclaration)
        name = decl.var
        type = decl.type
        default = decl.value
      else
        raise "enum_attribute expects a type declaration like 'status : Status'"
      end
    %}
    
    {% column_type = options[:column_type] || String %}
    {% converter = options[:converter] %}
    
    # Define the column with enum converter
    {% if converter %}
      column {{name}} : {{type}}, converter: {{converter}}
    {% else %}
      {% if type.resolve.nilable? %}
        {% enum_converter_type = type.resolve.union_types.find { |t| t != Nil } %}
      {% else %}
        {% enum_converter_type = type %}
      {% end %}
      column {{name}} : {{type}}, converter: Grant::Converters::Enum({{enum_converter_type}}, {{column_type}})
    {% end %}
    
    # Generate helper methods for each enum value
    {% if type.resolve.nilable? %}
      {% enum_type = type.resolve.union_types.find { |t| t != Nil } %}
    {% else %}
      {% enum_type = type.resolve %}
    {% end %}
    
    {% for member in enum_type.constants %}
      # Predicate method (e.g., draft?)
      def {{member.underscore}}? : Bool
        {{name}} == {{enum_type}}::{{member}}
      end
      
      # Bang method to set value (e.g., published!)
      def {{member.underscore}}! : {{enum_type}}
        self.{{name}} = {{enum_type}}::{{member}}
      end
    {% end %}
    
    # Scope for each enum value
    {% for member in enum_type.constants %}
      def self.{{member.underscore}}
        where({{name}}: {{enum_type}}::{{member}})
      end
    {% end %}
    
    # Class methods to access enum values
    def self.{{name.id}}s
      {{enum_type}}.values
    end
    
    # Return mapping of enum names to values
    def self.{{name.id}}_mapping
      {
        {% for member in enum_type.constants %}
          {{member.underscore.stringify}} => {{enum_type}}::{{member}},
        {% end %}
      }
    end
    
    # Add default value if specified
    {% if default %}
      after_initialize do
        if @{{name}}.nil? && new_record?
          @{{name}} = {% if default.is_a?(SymbolLiteral) %}
            {{enum_type}}::{{default.id.camelcase}}
          {% else %}
            {{default}}
          {% end %}
        end
      end
    {% end %}
  end
  
  # Macro for defining multiple enum attributes at once
  macro enum_attributes(**mappings)
    {% for name, config in mappings %}
      {% if config.is_a?(HashLiteral) %}
        enum_attribute {{name}} : {{config[:type]}}, {{**config}}
      {% else %}
        enum_attribute {{name}} : {{config}}
      {% end %}
    {% end %}
  end
  
  # Helper module for enum validations
  module Validations
    # Validate that enum value is within allowed values
    macro validates_enum(field, **options)
      {% message = options[:message] || "is not a valid value" %}
      {% allow_nil = options[:allow_nil] || false %}
      
      validate "{{field}} {{message}}" do |model|
        value = model.{{field}}
        {% if allow_nil %}
          value.nil? || {{field.id.camelcase}}.valid?(value)
        {% else %}
          !value.nil? && {{field.id.camelcase}}.valid?(value)
        {% end %}
      end
    end
  end
end

# Include in Grant::Base
abstract class Grant::Base
  include Grant::EnumAttributes
  extend Grant::EnumAttributes::Validations
end