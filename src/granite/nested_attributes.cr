# Improved nested attributes implementation with explicit types  
module Granite::NestedAttributes
  macro included
    # Storage for nested attributes data
    @_nested_attributes_data = {} of String => Array(Hash(String, Granite::Columns::Type))
    
    # Track if we have nested attributes to avoid unnecessary overhead
    @_has_nested_attributes = false
  end
  
  # Macro to enable automatic nested saves via callbacks
  # Call this after all accepts_nested_attributes_for declarations
  macro enable_nested_saves
    after_save :save_all_nested_attributes
    
    private def save_all_nested_attributes
      return true unless @_has_nested_attributes
      return true if @_nested_attributes_data.empty?
      
      success = true
      
      # Process each association's nested attributes
      {% for method in @type.methods.select { |m| m.name.starts_with?("save_nested_") } %}
        {% assoc_name = method.name.gsub(/^save_nested_/, "") %}
        if attrs = @_nested_attributes_data[{{ assoc_name.stringify }}]?
          success = {{ method.name.id }} && success
        end
      {% end %}
      
      # Clear nested data after processing
      @_nested_attributes_data.clear if success
      
      success
    end
  end
  
  # Improved macro that validates association exists and requires explicit types
  macro accepts_nested_attributes_for(association, **options)
    {% 
      # Extract association name and class from the declaration
      if association.is_a?(TypeDeclaration)
        assoc_name = association.var
        target_class = association.type
      else
        # Require explicit type declaration for compile-time safety
        raise "accepts_nested_attributes_for requires explicit type declaration. Use: accepts_nested_attributes_for #{association} : ClassName"
      end
    %}
    
    # Flag that this model has nested attributes
    @_has_nested_attributes = true
    
    # Generate the attributes setter method
    def {{assoc_name.id}}_attributes=(attributes)
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
      
      @_nested_attributes_data[{{ assoc_name.stringify }}] = processed_attrs
    end
    
    # Get nested attributes (for testing)
    def {{assoc_name.id}}_nested_attributes
      @_nested_attributes_data[{{ assoc_name.stringify }}]?
    end
    
    # Generate save method for this specific association
    private def save_nested_{{assoc_name.id}} : Bool
      attrs_array = @_nested_attributes_data[{{ assoc_name.stringify }}]
      return true unless attrs_array
      return true if attrs_array.empty?
      
      config = {
        allow_destroy: {{ options[:allow_destroy] || false }},
        update_only: {{ options[:update_only] || false }}
      }
      
      # Get foreign key from association metadata
      {% if @type.has_constant?("_#{assoc_name.id}_association_meta") %}
        foreign_key_name = self.class._{{assoc_name.id}}_association_meta[:foreign_key]
        assoc_type = self.class._{{assoc_name.id}}_association_meta[:type]
      {% else %}
        foreign_key_name = "#{self.class.name.split("::").last.underscore}_id"
        assoc_type = :has_many
      {% end %}
      
      success = true
      
      attrs_array.each do |attr_hash|
        begin
          if config[:allow_destroy] && should_destroy?(attr_hash)
            # Handle destroy
            if id = attr_hash["id"]?
              if record = {{target_class}}.find(id)
                unless record.destroy
                  record.errors.each do |error|
                    self.errors << Granite::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
                  end
                  success = false
                end
              end
            end
          elsif id = attr_hash["id"]?
            # Handle update
            if record = {{target_class}}.find(id)
              # Update attributes
              update_attrs = {} of String => String
              attr_hash.each do |key, value|
                next if key == "id" || key == "_destroy"
                update_attrs[key] = value.to_s
              end
              
              record.set_attributes(update_attrs)
              
              unless record.save
                record.errors.each do |error|
                  self.errors << Granite::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
                end
                success = false
              end
            end
          elsif !config[:update_only]
            # Handle create
            record = {{target_class}}.new
            
            # Set attributes
            create_attrs = {} of String => String
            attr_hash.each do |key, value|
              next if key == "id" || key == "_destroy"
              create_attrs[key] = value.to_s
            end
            
            record.set_attributes(create_attrs)
            
            # Set foreign key for has_many/has_one associations
            if (assoc_type == :has_many || assoc_type == :has_one) && self.id
              record.set_attributes({foreign_key_name => self.id.to_s})
            end
            
            unless record.save
              record.errors.each do |error|
                self.errors << Granite::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
              end
              success = false
            end
          end
        rescue ex
          Log.error { "Error processing nested attributes for {{ assoc_name.id }}: #{ex.message}" }
          self.errors << Granite::Error.new("{{ assoc_name.id }}", ex.message.to_s)
          success = false
        end
      end
      
      success
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
  
  private def should_destroy?(attrs : Hash(String, Granite::Columns::Type))
    return false unless val = attrs["_destroy"]?
    case val
    when Bool then val
    when String then val == "true" || val == "1"
    when Int32, Int64 then val == 1
    else false
    end
  end
  
  # Get all nested attributes data
  def nested_attributes_data
    @_nested_attributes_data
  end
end