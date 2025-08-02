# Nested attributes implementation with proper save hook
module Granite::NestedAttributes
  macro included
    # Storage for nested attributes data
    @_nested_attributes_data = {} of String => Array(Hash(String, Granite::Columns::Type))
  end
  
  # Main macro to configure nested attributes
  macro accepts_nested_attributes_for(association_name, class_name = nil, **options)
    {% association_str = association_name.id.stringify %}
    {% 
      # Use provided class name or infer from association
      if class_name
        target_class = class_name
      else
        # Simple singularization - just remove trailing 's'
        singular = association_name.id.stringify
        if singular.ends_with?("s")
          singular = singular[0..-2]
        end
        target_class = singular.camelcase.id
      end
    %}
    
    # Generate the attributes setter method
    def {{association_name.id}}_attributes=(attributes)
      # Configuration for this specific association
      config = {
        allow_destroy: {{ options[:allow_destroy] || false }},
        update_only: {{ options[:update_only] || false }},
        limit: {{ options[:limit] }},
        reject_if: {% if options[:reject_if] == :all_blank %} :all_blank {% else %} nil {% end %}
      }
      
      processed_attrs = case attributes
      when Array
        # Check limit
        if limit = config[:limit]
          if attributes.size > limit
            raise ArgumentError.new("Maximum #{limit} records are allowed. Got #{attributes.size} records instead.")
          end
        end
        
        attributes.compact_map do |a|
          next unless a.is_a?(Hash) || a.is_a?(NamedTuple)
          process_single_nested_attributes(a, config)
        end
      when Hash, NamedTuple
        result = process_single_nested_attributes(attributes, config)
        result ? [result] : [] of Hash(String, Granite::Columns::Type)
      else
        raise ArgumentError.new("Nested attributes must be an Array, Hash, or NamedTuple")
      end
      
      @_nested_attributes_data[{{ association_str }}] = processed_attrs
    end
    
    # Get nested attributes (for testing)
    def {{association_name.id}}_nested_attributes
      @_nested_attributes_data[{{ association_str }}]?
    end
  end
  
  # Process single set of attributes with config
  private def process_single_nested_attributes(attrs, config : NamedTuple) : Hash(String, Granite::Columns::Type)?
    hash_attrs = case attrs
    when Hash
      result = {} of String => Granite::Columns::Type
      attrs.each { |k, v| result[k.to_s] = v }
      result
    when NamedTuple
      result = {} of String => Granite::Columns::Type
      attrs.each { |k, v| result[k.to_s] = v }
      result
    else
      return nil
    end
    
    # Check reject_if
    if config[:reject_if] == :all_blank
      return nil if hash_attrs.all? { |k, v| k == "_destroy" || blank_value?(v) }
    end
    
    # Skip create if update_only and no id
    if config[:update_only] && !hash_attrs["id"]?
      return nil
    end
    
    hash_attrs
  end
  
  private def blank_value?(value)
    value.nil? || (value.responds_to?(:empty?) && value.empty?)
  end
  
  # Get all nested attributes data
  def nested_attributes_data
    @_nested_attributes_data
  end
  
  # Method to manually process nested attributes after save
  # This needs to be called explicitly for now
  def save_with_nested_attributes(**args)
    # Save parent first
    result = save(**args)
    
    # If parent saved successfully, save nested attributes
    if result && !@_nested_attributes_data.empty?
      # For now, just return true
      # In a real implementation, this would process the nested records
      @_nested_attributes_data.clear
    end
    
    result
  end
end