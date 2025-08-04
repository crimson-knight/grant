module Granite::ValueObjects
  # Stores metadata about value object aggregations
  class AggregationMeta
    getter name : String
    getter class_name : String
    getter mapping : Hash(String, Symbol)
    getter allow_nil : Bool
    getter has_custom_constructor : Bool
    
    def initialize(@name : String, @class_name : String, @mapping : Hash(String, Symbol), @has_custom_constructor : Bool = false, @allow_nil : Bool = false)
    end
  end
  
  # Exception for value object errors
  class ValueObjectError < Exception
  end
  
  macro aggregation(name, class_name = nil, mapping = nil, constructor = nil, allow_nil = false)
    {% if class_name.is_a?(NamedTupleLiteral) %}
      # Handle case where class_name is omitted and mapping is first arg
      {% actual_mapping = class_name %}
      {% actual_class_name = name.id.stringify.camelcase %}
      {% actual_constructor = mapping %}
      {% actual_allow_nil = constructor || false %}
    {% else %}
      {% actual_mapping = mapping %}
      {% actual_class_name = class_name || name.id.stringify.camelcase %}
      {% actual_constructor = constructor %}
      {% actual_allow_nil = allow_nil %}
    {% end %}
    
    {% method_name = name.id %}
    {% klass = actual_class_name.id %}
    {% mapping_hash = actual_mapping %}
    
    # Store aggregation metadata
    class_getter _{{method_name}}_aggregation_meta = Granite::ValueObjects::AggregationMeta.new(
      {{name.stringify}},
      {{actual_class_name.stringify}},
      { {% for key, value in mapping_hash %}{{key.stringify}} => {{value}},{% end %} },
      {% if actual_constructor %}true{% else %}false{% end %},
      {{actual_allow_nil}}
    )
    
    # Register all columns that are part of this aggregation
    {% for column_name, attr_name in mapping_hash %}
      # Store all as strings and convert when needed
      column {{column_name.id}} : String?
    {% end %}
    
    # Instance variable to cache the value object
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_cached_{{method_name}} : {{klass}}?
    
    # Define getter method
    def {{method_name}} : {{klass}}?
      # Return cached value if columns haven't changed
      if @_cached_{{method_name}} && !aggregation_changed?({{name.stringify}})
        return @_cached_{{method_name}}
      end
      
      # Check if all required columns have values
      {% if actual_allow_nil %}
        # If allow_nil is true, return nil if all columns are nil
        all_nil = true
        {% for column_name, attr_name in mapping_hash %}
          all_nil = false unless @{{column_name.id}}.nil?
        {% end %}
        return nil if all_nil
      {% else %}
        # If allow_nil is false, check if any column is nil
        {% for column_name, attr_name in mapping_hash %}
          return nil if @{{column_name.id}}.nil?
        {% end %}
      {% end %}
      
      # Build the value object
      @_cached_{{method_name}} = {% if actual_constructor %}
        # Use custom constructor
        result = {{actual_constructor}}.call(
          {% for column_name, attr_name in mapping_hash %}
            @{{column_name.id}},
          {% end %}
        )
        result.as({{klass}}?)
      {% else %}
        # Use default constructor with named arguments
        {{klass}}.new(
          {% for column_name, attr_name in mapping_hash %}
            {{attr_name.id}}: @{{column_name.id}}.not_nil!,
          {% end %}
        )
      {% end %}
    end
    
    # Define setter method
    def {{method_name}}=(value : {{klass}}?)
      # Track changes for dirty tracking
      old_value = {{method_name}}
      
      if value.nil?
        {% for column_name, attr_name in mapping_hash %}
          write_attribute({{column_name.stringify}}, nil)
        {% end %}
      else
        {% for column_name, attr_name in mapping_hash %}
          write_attribute({{column_name.stringify}}, value.{{attr_name.id}}.to_s)
        {% end %}
      end
      
      # Clear cache
      @_cached_{{method_name}} = nil
      
      # Track aggregation change
      track_aggregation_change({{name.stringify}}, old_value, value)
    end
    
    # Check if the aggregation has changed
    def {{method_name}}_changed? : Bool
      aggregation_changed?({{name.stringify}})
    end
    
    # Get the previous value of the aggregation
    def {{method_name}}_was : {{klass}}?
      aggregation_was({{name.stringify}}).as({{klass}}?)
    end
    
    # Add to list of aggregations for introspection
    
    # Add validation support
    validate "{{method_name}} value object validation" do |instance|
      # Skip validation if allow_nil and value is nil
      {% if actual_allow_nil %}
        next true if instance.{{method_name}}.nil?
      {% end %}
      
      # Try to build the value object - will raise if invalid
      begin
        value = instance.{{method_name}}
        
        # If value object has a validate method, call it
        if value.responds_to?(:validate)
          vo_errors = value.validate
          if vo_errors.responds_to?(:empty?) && !vo_errors.empty?
            # Assume vo_errors is an array of Error objects
            vo_errors.each do |vo_error|
              instance.errors << Granite::Error.new(:{{method_name}}, "#{vo_error.field} #{vo_error.message}")
            end
            next false
          end
        end
        true
      rescue ex : Exception
        instance.errors << Granite::Error.new(:{{method_name}}, "is invalid: #{ex.message}")
        false
      end
    end
  end
  
  # Module to be included in models for value object support
  module ClassMethods
    # This will be populated by each model
  end
  
  # Empty placeholder - aggregations method will be generated in the model's macro finished
  
  # Empty placeholder - methods will be generated in the combined macro finished
  
  # Macro to generate all value object methods
  macro finished
    # Dirty tracking for aggregations  
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @aggregation_changes = {} of String => Tuple(String?, String?)
    
    # Generate aggregations class method
    def self.aggregations
      aggregations = {} of Symbol => AggregationMeta
      {% for ivar in @type.class.instance_vars %}
        {% if ivar.name.ends_with?("_aggregation_meta") && ivar.name.starts_with?("_") %}
          {% name = ivar.name.gsub(/^_/, "").gsub(/_aggregation_meta$/, "") %}
          aggregations[{{name.id.symbolize}}] = {{ivar.name.id}}
        {% end %}
      {% end %}
      aggregations
    end
    
    # Track aggregation changes
    protected def track_aggregation_change(name : String, old_value, new_value)
      # Convert value objects to strings for storage
      old_str = old_value.responds_to?(:to_s) ? old_value.to_s : nil
      new_str = new_value.responds_to?(:to_s) ? new_value.to_s : nil
      return if old_str == new_str
      @aggregation_changes[name] = {old_str, new_str}
    end
    
    # Check if an aggregation has changed
    def aggregation_changed?(name : String) : Bool
      # Check if any of the columns for this aggregation have changed
      case name
      {% for ivar in @type.class.instance_vars %}
        {% if ivar.name.ends_with?("_aggregation_meta") && ivar.name.starts_with?("_") %}
          {% name = ivar.name.gsub(/^_/, "").gsub(/_aggregation_meta$/, "") %}
          when {{name.stringify}}
            meta = self.class.{{ivar.name.id}}
            meta.mapping.keys.any? { |col| attribute_changed?(col) }
        {% end %}
      {% end %}
      else
        false
      end
    end
    
    # Get the previous value of an aggregation
    def aggregation_was(name : String)
      if @aggregation_changes.has_key?(name)
        @aggregation_changes[name][0]
      else
        read_aggregation(name)
      end
    end
    
    # Instance methods for value object handling
    def read_aggregation(name : String | Symbol)
      case name.to_s
      {% for ivar in @type.class.instance_vars %}
        {% if ivar.name.ends_with?("_aggregation_meta") && ivar.name.starts_with?("_") %}
          {% name = ivar.name.gsub(/^_/, "").gsub(/_aggregation_meta$/, "") %}
          when {{name.stringify}}
            {{name.id}}
        {% end %}
      {% end %}
      else
        nil
      end
    end
    
    def write_aggregation(name : String | Symbol, value)
      case name.to_s
      {% for ivar in @type.class.instance_vars %}
        {% if ivar.name.ends_with?("_aggregation_meta") && ivar.name.starts_with?("_") %}
          {% name = ivar.name.gsub(/^_/, "").gsub(/_aggregation_meta$/, "") %}
          when {{name.stringify}}
            self.{{name.id}} = value
        {% end %}
      {% end %}
      end
    end
    
    # Clear aggregation changes after save
    # TODO: Fix callback registration in value objects
    # after_save do
    #   @aggregation_changes.clear if @aggregation_changes
    # end
    
    # Override set_attributes to handle value objects
    def set_attributes(args : Granite::ModelArgs)
      args.each do |k, v|
        if {% for ivar in @type.class.instance_vars %}
             {% if ivar.name.ends_with?("_aggregation_meta") && ivar.name.starts_with?("_") %}
               {% name = ivar.name.gsub(/^_/, "").gsub(/_aggregation_meta$/, "") %}
               k.to_s == {{name.stringify}} ||
             {% end %}
           {% end %} false
          write_aggregation(k, v)
        else
          write_attribute(k, v)
        end
      end
    end
  end
  
  # Empty placeholder - set_attributes will be generated in macro finished
end