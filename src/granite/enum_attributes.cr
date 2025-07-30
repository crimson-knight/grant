# Enum Attributes for Grant ORM
#
# Provides Rails-style enum attributes with helper methods for Crystal enums.
# 
# Example:
# ```crystal
# class Post < Granite::Base
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

module Granite::EnumAttributes
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
      column {{name}} : {{type}}, converter: Granite::Converters::Enum({{type}}, {{column_type}})
    {% end %}
    
    # Generate helper methods for each enum value
    {% for member in type.resolve.constants %}
      # Predicate method (e.g., draft?)
      def {{member.underscore}}? : Bool
        {{name}} == {{type}}::{{member}}
      end
      
      # Bang method to set value (e.g., published!)
      def {{member.underscore}}! : {{type}}
        self.{{name}} = {{type}}::{{member}}
      end
    {% end %}
    
    # Scope for each enum value
    {% for member in type.resolve.constants %}
      scope :{{member.underscore}}, -> { where({{name}}: {{type}}::{{member}}) }
    {% end %}
    
    # Class methods to access enum values
    def self.{{name.id}}s
      {{type}}.values
    end
    
    # Return mapping of enum names to values
    def self.{{name.id}}_mapping
      {
        {% for member in type.resolve.constants %}
          {{member.underscore.stringify}} => {{type}}::{{member}},
        {% end %}
      }
    end
    
    # Add default value if specified
    {% if default %}
      after_initialize do
        if @{{name}}.nil? && new_record?
          @{{name}} = {% if default.is_a?(SymbolLiteral) %}
            {{type}}::{{default.id.camelcase}}
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

# Include in Granite::Base
abstract class Granite::Base
  include Granite::EnumAttributes
  extend Granite::EnumAttributes::Validations
end