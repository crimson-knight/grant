# Improved nested attributes implementation with explicit types
module Grant::NestedAttributes
  macro included
    # Storage for nested attributes data.
    # Declared nilable (with lazy initialization in `_nested_attributes_data`
    # below) rather than carrying a default value so that `YAML::Serializable` /
    # `JSON::Serializable`'s auto-generated deserialization initializer — included
    # on the abstract `Grant::Base` — does not report it as uninitialized for
    # `Grant::Base+`. See issues #39/#41.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_nested_attributes_data : Hash(String, Array(Hash(String, Grant::Columns::Type)))?

    protected def _nested_attributes_data : Hash(String, Array(Hash(String, Grant::Columns::Type)))
      @_nested_attributes_data ||= {} of String => Array(Hash(String, Grant::Columns::Type))
    end

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_grant_nested_owner_foreign_keys_to_skip : Array(String)?

    def _grant_skip_nested_owner_foreign_key_validation(foreign_key : String) : Nil
      keys = @_grant_nested_owner_foreign_keys_to_skip ||= [] of String
      keys << foreign_key unless keys.includes?(foreign_key)
    end

    def _grant_nested_owner_foreign_key_skipped?(foreign_key : String) : Bool
      @_grant_nested_owner_foreign_keys_to_skip.try(&.includes?(foreign_key)) || false
    end

    def _grant_nested_saves_enabled? : Bool
      false
    end

    # Track if we have nested attributes to avoid unnecessary overhead.
    # Nilable for the same reason as above; `nil` is treated as `false`.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_has_nested_attributes : Bool?
  end

  # Macro to enable automatic nested saves via callbacks
  # Call this after all accepts_nested_attributes_for declarations
  macro enable_nested_saves
    def _grant_nested_saves_enabled? : Bool
      true
    end

    after_save :save_all_nested_attributes
    
    private def save_all_nested_attributes
      return true unless @_has_nested_attributes
      return true if _nested_attributes_data.empty?

      success = true

      # Process each association's nested attributes
      {% for method in @type.methods.select { |m| m.name.starts_with?("save_nested_") } %}
        {% assoc_name = method.name.gsub(/^save_nested_/, "") %}
        if attrs = _nested_attributes_data[{{ assoc_name.stringify }}]?
          success = {{ method.name.id }} && success
        end
      {% end %}

      # Clear nested data after processing
      _nested_attributes_data.clear if success
      
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

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{assoc_name.id}}_nested_owner_was_new : Bool? = nil
    
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
        result ? [result] : [] of Hash(String, Grant::Columns::Type)
      else
        raise ArgumentError.new("Nested attributes must be an Array, Hash, or NamedTuple")
      end

      @_{{assoc_name.id}}_nested_owner_was_new = self.new_record?
      _nested_attributes_data[{{ assoc_name.stringify }}] = processed_attrs
    end

    validate "nested {{assoc_name.id}} must be valid" do |owner|
      nested_valid = true
      {% if options[:update_only] %}
      validate_nested = owner.new_record?
      {% else %}
      validate_nested = true
      {% end %}
      if validate_nested && (attrs_array = owner._nested_attributes_data[{{assoc_name.stringify}}]?)
        attrs_array.each do |attr_hash|
          next if attr_hash["_destroy"]?.try(&.to_s) == "true"

          nested_record = {{target_class.id}}.new
          nested_attributes = {} of String => String
          attr_hash.each do |key, value|
            next if key == "id" || key == "_destroy"
          nested_attributes[key] = value.to_s
          end
          nested_record.set_attributes(nested_attributes)
          if owner.new_record? && owner._grant_nested_saves_enabled?
            if association = Grant::AssociationRegistry.get(owner.class.name, {{assoc_name.stringify}})
              if association[:type] == :has_many || association[:type] == :has_one
                nested_record._grant_skip_nested_owner_foreign_key_validation(association[:foreign_key])
              end
            end
          end
          unless nested_record.valid?
            nested_record.errors.each do |error|
              owner.errors << Grant::Error.new("{{assoc_name.id}}.#{error.field}", error.message)
            end
            nested_valid = false
          end
        end
      end
      nested_valid
    end

    # Get nested attributes (for testing)
    def {{assoc_name.id}}_nested_attributes
      _nested_attributes_data[{{ assoc_name.stringify }}]?
    end

    # Resolve IDs through this owner's association so another parent's
    # records cannot be updated or destroyed by submitting their primary key.
    private def find_nested_{{assoc_name.id}}_by_id(id : Grant::Columns::Type) : {{target_class.id}}?
      association = self.{{assoc_name.id}}
      if association.responds_to?(:all)
        association.all.to_a.find do |record|
          record.primary_key_value.to_s == id.to_s
        end
      elsif record = association
        if !record.new_record? && record.primary_key_value.to_s == id.to_s
          record
        end
      end
    end

    # `update_only` without an ID applies to the current singular association
    # (or the first record for a collection association).
    private def first_nested_{{assoc_name.id}} : {{target_class.id}}?
      association = self.{{assoc_name.id}}
      if association.responds_to?(:all)
        association.all.to_a.first?
      elsif record = association
        record unless record.new_record?
      end
    end

    # Generate save method for this specific association
    private def save_nested_{{assoc_name.id}} : Bool
      attrs_array = _nested_attributes_data[{{ assoc_name.stringify }}]
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
            record = if id = attr_hash["id"]?
                       find_nested_{{assoc_name.id}}_by_id(id)
                     elsif config[:update_only]
                       first_nested_{{assoc_name.id}}
                     end

            if record
                unless record.destroy
                  record.errors.each do |error|
                    self.errors << Grant::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
                  end
                  success = false
                end
            elsif attr_hash.has_key?("id") || config[:update_only]
              self.errors << Grant::Error.new("{{ assoc_name.id }}", "Nested record is not associated with this record")
              success = false
            end
          elsif id = attr_hash["id"]?
            # Handle update
            if record = find_nested_{{assoc_name.id}}_by_id(id)
              # Update attributes
              update_attrs = {} of String => String
              attr_hash.each do |key, value|
                next if key == "id" || key == "_destroy"
                update_attrs[key] = value.to_s
              end
              
              record.set_attributes(update_attrs)
              
              unless record.save
                record.errors.each do |error|
                  self.errors << Grant::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
                end
                success = false
              end
            else
              self.errors << Grant::Error.new("{{ assoc_name.id }}", "Record with id #{id} is not associated with this record")
              success = false
            end
          elsif config[:update_only] && !@_{{assoc_name.id}}_nested_owner_was_new
            if record = first_nested_{{assoc_name.id}}
              update_attrs = {} of String => String
              attr_hash.each do |key, value|
                next if key == "_destroy"
                update_attrs[key] = value.to_s
              end

              record.set_attributes(update_attrs)

              unless record.save
                record.errors.each do |error|
                  self.errors << Grant::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
                end
                success = false
              end
            else
              self.errors << Grant::Error.new("{{ assoc_name.id }}", "Associated record not found for update_only nested attributes")
              success = false
            end
          else
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
                self.errors << Grant::Error.new("{{ assoc_name.id }}.#{error.field}", error.message)
              end
              success = false
            end
          end
        rescue ex
          Log.error { "Error processing nested attributes for {{ assoc_name.id }}: #{ex.message}" }
          self.errors << Grant::Error.new("{{ assoc_name.id }}", ex.message.to_s)
          success = false
        end
      end
      
      success
    end
  end

  # Process single set of attributes with config
  private def process_single_nested_attributes(attrs, config : NamedTuple) : Hash(String, Grant::Columns::Type)?
    hash_attrs = case attrs
                 when Hash
                   result = {} of String => Grant::Columns::Type
                   attrs.each { |k, v| result[k.to_s] = v }
                   result
                 when NamedTuple
                   result = {} of String => Grant::Columns::Type
                   attrs.each { |k, v| result[k.to_s] = v }
                   result
                 else
                   return nil
                 end

    # Check reject_if
    if config[:reject_if] == :all_blank
      return nil if hash_attrs.all? { |k, v| k == "_destroy" || blank_value?(v) }
    end

    if config[:update_only] && !hash_attrs.has_key?("id") && !_grant_nested_saves_enabled?
      return nil
    end

    hash_attrs
  end

  private def blank_value?(value)
    value.nil? || (value.responds_to?(:empty?) && value.empty?)
  end

  private def should_destroy?(attrs : Hash(String, Grant::Columns::Type))
    return false unless val = attrs["_destroy"]?
    case val
    when Bool         then val
    when String       then val == "true" || val == "1"
    when Int32, Int64 then val == 1
    else                   false
    end
  end

  # Get all nested attributes data
  def nested_attributes_data
    _nested_attributes_data
  end
end
