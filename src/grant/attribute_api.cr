# # Attribute API
# 
# The Attribute API provides a flexible way to define custom attributes with
# type casting, default values, and virtual attributes that aren't backed by
# database columns.
#
# ## Features
#
# - Custom type casting with type-safe conversions
# - Default values with procs/lambdas support
# - Virtual attributes not backed by database columns
# - Type coercion for common conversions
# - Integration with dirty tracking
#
# ## Usage
#
# ```crystal
# class Product < Grant::Base
#   # Virtual attribute with custom type
#   attribute :price_in_cents, Int32, virtual: true
#   
#   # Attribute with default value
#   attribute :status, String, default: "active"
#   
#   # Attribute with proc default
#   attribute :code, String, default: ->(product : Product) { "PROD-#{product.id}" }
#   
#   # Custom type with converter
#   attribute :metadata, ProductMetadata, converter: ProductMetadataConverter
# end
# ```
module Grant::AttributeApi
  # Use macro to define attribute storage at the class level
  macro included
    # Storage for attribute definitions - using a simpler approach
    class_property attribute_definitions = {} of String => NamedTuple(
      name: String,
      type: String,
      virtual: Bool,
      has_default: Bool,
      has_converter: Bool
    )
  end
  
  # Define a custom attribute
  macro attribute(decl, **options)
      {% name = decl.var %}
      {% type = decl.type %}
      {% virtual = options[:virtual] || false %}
      {% converter = options[:converter] %}
      {% default = options[:default] %}
      {% cast = options[:cast] %}
      
      # Store attribute metadata
      @@attribute_definitions[{{name.stringify}}] = {
        name: {{name.stringify}},
        type: {{type.stringify}},
        virtual: {{virtual}},
        has_default: {{default != nil}},
        has_converter: {{converter != nil}}
      }
      
      {% if virtual %}
        # Virtual attributes aren't backed by DB columns
        @[JSON::Field(ignore: true)]
        @[YAML::Field(ignore: true)]
        @{{name}} : {{type}}?
        
        # Getter with default value support
        def {{name}} : {{type}}?
          if @{{name}}.nil?
            {% if default %}
              {% if default.is_a?(ProcLiteral) %}
                @{{name}} = {{default}}.call(self)
              {% else %}
                @{{name}} = {{default}}
              {% end %}
            {% end %}
          end
          @{{name}}
        end
        
        # Setter with dirty tracking
        def {{name}}=(value : {{type}}?)
          ensure_dirty_tracking_initialized
          
          if !new_record? && @{{name}} != value
            if !@original_attributes.not_nil!.has_key?({{name.stringify}})
              @original_attributes.not_nil![{{name.stringify}}] = @{{name}}.as(Grant::Base::DirtyValue)
            end
            
            original = @original_attributes.not_nil![{{name.stringify}}]
            if original == value
              @changed_attributes.not_nil!.delete({{name.stringify}})
            else
              @changed_attributes.not_nil![{{name.stringify}}] = {original, value.as(Grant::Base::DirtyValue)}
            end
          end
          
          @{{name}} = value
        end
        
        # Dirty tracking methods
        def {{name}}_changed? : Bool
          ensure_dirty_tracking_initialized
          @changed_attributes.not_nil!.has_key?({{name.stringify}})
        end
        
        def {{name}}_was : {{type}}?
          ensure_dirty_tracking_initialized
          if @changed_attributes.not_nil!.has_key?({{name.stringify}})
            @changed_attributes.not_nil![{{name.stringify}}][0].as({{type}}?)
          else
            @{{name}}
          end
        end
        
        def {{name}}_change : Tuple({{type}}?, {{type}}?)?
          ensure_dirty_tracking_initialized
          if change = @changed_attributes.not_nil![{{name.stringify}}]?
            {change[0].as({{type}}?), change[1].as({{type}}?)}
          end
        end
      {% else %}
        # Non-virtual attributes use the column macro with enhancements
        column {{name}} : {{type}}{% if converter %}, converter: {{converter}}{% end %}{% if options[:column_type] %}, column_type: {{options[:column_type]}}{% end %}{% if options[:primary] %}, primary: {{options[:primary]}}{% end %}{% if options[:auto] %}, auto: {{options[:auto]}}{% end %}
        
        # Override getter to support default values
        {% if default %}
          def {{name}}
            value = @{{name}}
            if value.nil?
              {% if default.is_a?(ProcLiteral) %}
                {{default}}.call(self)
              {% else %}
                {{default}}
              {% end %}
            else
              value
            end
          end
        {% end %}
        
        # Add type casting support
        {% if cast %}
          def {{name}}=(value)
            casted_value = {{cast}}.call(value)
            super(casted_value.as({{type}}))
          end
        {% end %}
      {% end %}
    end
    
  # Define multiple attributes at once
  macro attributes(**attrs)
    {% for name, options in attrs %}
      {% if options.is_a?(HashLiteral) %}
        attribute {{name}} : {{options[:type]}}, {{**options}}
      {% else %}
        attribute {{name}} : {{options}}
      {% end %}
    {% end %}
  end
  
  # Instance methods for attribute API
  
  # Get all custom attribute names
  def custom_attribute_names : Array(String)
    self.class.attribute_definitions.keys
  end
  
  # Get all virtual attribute names
  def virtual_attribute_names : Array(String)
    self.class.attribute_definitions.select { |_, definition| definition[:virtual] }.keys
  end
  
  # Check if an attribute is virtual
  def virtual_attribute?(name : String) : Bool
    if attr_def = self.class.attribute_definitions[name]?
      attr_def[:virtual]
    else
      false
    end
  end
  
  
  # Common type casters
  module TypeCasters
    # Cast to String
    def self.to_string(value) : String?
      case value
      when Nil
        nil
      when String
        value
      else
        value.to_s
      end
    end
    
    # Cast to Int32
    def self.to_int32(value) : Int32?
      case value
      when Nil
        nil
      when Int32
        value
      when String
        value.to_i32?
      when Number
        value.to_i32
      else
        nil
      end
    end
    
    # Cast to Float64
    def self.to_float64(value) : Float64?
      case value
      when Nil
        nil
      when Float64
        value
      when String
        value.to_f64?
      when Number
        value.to_f64
      else
        nil
      end
    end
    
    # Cast to Bool
    def self.to_bool(value) : Bool?
      case value
      when Nil
        nil
      when Bool
        value
      when String
        case value.downcase
        when "true", "1", "yes", "on"
          true
        when "false", "0", "no", "off"
          false
        else
          nil
        end
      when Number
        value != 0
      else
        nil
      end
    end
    
    # Cast to Time
    def self.to_time(value) : Time?
      case value
      when Nil
        nil
      when Time
        value
      when String
        Time.parse_rfc3339(value)
      else
        nil
      end
    end
  end
end

# Module will be included in Grant::Base