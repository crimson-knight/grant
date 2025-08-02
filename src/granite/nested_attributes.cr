# Improved nested attributes implementation with explicit types
module Granite::NestedAttributes
  macro included
    # Storage for nested attributes data
    @_nested_attributes_data = {} of String => Array(Hash(String, Granite::Columns::Type))
    
    # Track if we have nested attributes to avoid unnecessary overhead
    @_has_nested_attributes = false
    
    # Override save to handle nested attributes if configured
    macro finished
      {% if @type.methods.any? { |m| m.name.ends_with?("_attributes=") } %}
        def save(**args)
          if @_has_nested_attributes && !@_nested_attributes_data.empty?
            transaction do
              # Save parent first
              result = previous_def
              
              # If parent saved successfully, process nested attributes
              if result
                save_nested_attributes
              else
                raise Granite::Callbacks::Abort.new("Parent record failed to save")
              end
            end
          else
            previous_def
          end
        end
        
        def save!(**args)
          if @_has_nested_attributes && !@_nested_attributes_data.empty?
            transaction do
              # Save parent first
              previous_def
              
              # Process nested attributes (will raise on failure)
              save_nested_attributes
            end
          else
            previous_def
          end
        end
        
        private def save_nested_attributes
          success = true
          
          # Process each association's nested attributes
          {% for method in @type.methods.select { |m| m.name.ends_with?("_attributes=") } %}
            {% assoc_name = method.name.gsub(/_attributes=$/, "") %}
            if attrs = @_nested_attributes_data[{{ assoc_name.stringify }}]?
              success = save_nested_{{ assoc_name.id }} && success
            end
          {% end %}
          
          # Clear nested data after processing
          @_nested_attributes_data.clear if success
          
          success
        end
      {% end %}
    end
  end
  
  # Improved macro that works with association definitions
  macro accepts_nested_attributes_for(association, **options)
    {% 
      # Extract association name and class from the declaration
      if association.is_a?(TypeDeclaration)
        assoc_name = association.var
        target_class = association.type
      else
        assoc_name = association.id
        # Try to find the association definition to get the class
        target_class = nil
        @type.methods.each do |method|
          if method.name == assoc_name.id
            # Look for the return type annotation
            if method.return_type
              target_class = method.return_type
              break
            end
          end
        end
        
        # If not found, try to get from association metadata
        if !target_class && @type.has_constant?("_#{assoc_name.id}_association_meta")
          # This will be resolved at runtime, but we need compile-time type
          # So we'll require explicit type in this case
          raise "Cannot infer type for association #{assoc_name}. Please use: accepts_nested_attributes_for #{assoc_name} : ClassName"
        end
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
  
  # Alternative syntax that's more explicit
  macro accepts_nested_attributes_for(association_name, target_class, **options)
    accepts_nested_attributes_for({{association_name.id}} : {{target_class}}, {{**options}})
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