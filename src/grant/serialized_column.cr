require "./serialized_object"
require "./serializers/base"
require "./serializers/json"
require "./serializers/yaml"

# Store a rich Crystal object in a single database column, serialized as JSON or
# YAML.
#
# `serialized_column :settings, UserSettings` maps a `UserSettings` object to one
# string column (`_serialized_settings`). The object is deserialized lazily on
# read (and cached), and serialized on write and before save. The value type only
# needs `JSON::Serializable`/`YAML::Serializable`; if it also includes
# `Grant::SerializedObject`, in-place mutations are tracked for dirty checking.
#
# This module is mixed into every `Grant::Base`, so the macro is available on any
# model.
#
# ```
# class UserSettings
#   include JSON::Serializable
#   include YAML::Serializable
#   include Grant::SerializedObject # enables change tracking (optional)
#   property theme : String = "light"
#   property notifications : Bool = true
#
#   def initialize(@theme = "light", @notifications = true)
#   end
# end
#
# class User < Grant::Base
#   column id : Int64, primary: true
#   serialized_column :settings, UserSettings, format: :json
# end
#
# u = User.new
# u.settings = UserSettings.new(theme: "dark")
# u.settings.try(&.theme) # => "dark"
# u.settings_changed?     # => true
# u.save                  # persists `{"theme":"dark",...}` in _serialized_settings
# ```
module Grant::SerializedColumn
  # Internal hook overridden per serialized column so nested
  # `Grant::SerializedObject`s can flag their parent column as dirty. Not called
  # directly.
  def _mark_serialized_column_changed(attribute_name : String)
    # This will be overridden by each serialized_column macro
  end

  # Declares *name* as a column holding a serialized *klass* instance.
  #
  # For `serialized_column :settings, UserSettings` this generates:
  #
  # * the backing column `_serialized_settings : String?` (the raw JSON/YAML);
  # * `#settings : UserSettings?` — lazily deserializes and caches the object;
  # * `#settings=(value : UserSettings?)` — caches and serializes the object;
  # * `#settings=(value : String)` — assigns a raw serialized string directly;
  # * `#settings_changed? : Bool` — true if the object was replaced or (for
  #   `Grant::SerializedObject` values) mutated in place since the last save;
  # * `before_save`/`after_save` hooks that re-serialize and reset change tracking.
  #
  # *format* selects the serializer: `:json` (default), `:jsonb` (stored as JSON;
  # the distinction matters only to the PostgreSQL column type), or `:yaml`.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   serialized_column :settings, UserSettings           # JSON
  #   serialized_column :config, AppConfig, format: :yaml # YAML
  # end
  #
  # u = User.new
  # u.settings = UserSettings.new(theme: "dark")
  # u.settings_changed? # => true
  # u.save
  # u.settings_changed? # => false (reset after save)
  # ```
  macro serialized_column(name, klass, format = :json)
    {% format_class = format.id.stringify.upcase %}
    
    # Define the underlying column with a different name
    column _serialized_{{ name.id }} : String?
    
    # Store the serializer  
    @_{{ name.id }}_serializer = Grant::Serializers::{{ format_class.id }}.new
    
    # Cache for the deserialized object
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{ name.id }}_cache : {{ klass }}?
    
    # Track if the serialized column has been modified
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{ name.id }}_modified = false
    
    # Getter to return deserialized object
    def {{ name.id }} : {{ klass }}?
      return @_{{ name.id }}_cache if @_{{ name.id }}_cache
      
      if raw_value = @_serialized_{{ name.id }}
        obj = @_{{ name.id }}_serializer.deserialize(raw_value, {{ klass }})
        
        # Set up parent tracking if the object includes SerializedObject
        if obj.responds_to?(:_set_parent)
          obj._set_parent(self, {{ name.id.stringify }})
        end
        
        @_{{ name.id }}_cache = obj
        obj
      else
        nil
      end
    end
    
    # Custom setter
    def {{ name.id }}=(value : {{ klass }}?)
      @_{{ name.id }}_cache = value
      
      if value
        # Set up parent tracking if the object includes SerializedObject
        if value.responds_to?(:_set_parent)
          value._set_parent(self, {{ name.id.stringify }})
        end
        
        # Serialize immediately to store in the column
        @_serialized_{{ name.id }} = @_{{ name.id }}_serializer.serialize(value)
      else
        @_serialized_{{ name.id }} = nil
      end
      
      # Mark as changed for dirty tracking
      ensure_dirty_tracking_initialized
      
      # Track the change in the standard dirty tracking system
      if !new_record?
        original = @original_attributes.not_nil!["_serialized_{{ name.id }}"]? || nil
        current = @_serialized_{{ name.id }}.as(Grant::Base::DirtyValue?)
        
        if original != current
          @changed_attributes.not_nil!["_serialized_{{ name.id }}"] = {
            original || "".as(Grant::Base::DirtyValue), 
            current || "".as(Grant::Base::DirtyValue)
          }
        end
      end
      
      @_{{ name.id }}_modified = true
      
      value
    end
    
    # Check if the serialized column has changed
    def {{ name.id }}_changed?
      return true if @_{{ name.id }}_modified
      
      # Check dirty tracking for the underlying column
      if !new_record? && @changed_attributes
        if @changed_attributes.not_nil!.has_key?("_serialized_{{ name.id }}")
          return true
        end
      end
      
      # Also check if the cached object itself has changes
      if cached = @_{{ name.id }}_cache
        if cached.responds_to?(:changed?)
          return cached.changed?
        end
      end
      
      false
    end
    
    # Raw string setter (for direct column assignment)
    def {{ name.id }}=(value : String)
      @_{{ name.id }}_cache = nil
      @_serialized_{{ name.id }} = value
      
      # Mark as changed for dirty tracking
      ensure_dirty_tracking_initialized
      
      # Track the change in the standard dirty tracking system
      if !new_record?
        original = @original_attributes.not_nil!["_serialized_{{ name.id }}"]? || nil
        current = @_serialized_{{ name.id }}.as(Grant::Base::DirtyValue?)
        
        if original != current
          @changed_attributes.not_nil!["_serialized_{{ name.id }}"] = {
            original || "".as(Grant::Base::DirtyValue), 
            current || "".as(Grant::Base::DirtyValue)
          }
        end
      end
      
      @_{{ name.id }}_modified = true
    end
    
    # Ensure serialization before save
    before_save :_serialize_{{ name.id }}
    
    private def _serialize_{{ name.id }}
      if cached = @_{{ name.id }}_cache
        @_serialized_{{ name.id }} = @_{{ name.id }}_serializer.serialize(cached)
      end
    end
    
    # Reset tracking after save
    after_save :_reset_{{ name.id }}_tracking
    
    private def _reset_{{ name.id }}_tracking
      @_{{ name.id }}_modified = false
      if cached = @_{{ name.id }}_cache
        if cached.responds_to?(:reset_changes!)
          cached.reset_changes!
        end
      end
    end
    
    # Define helper method for this specific column
    def _mark_serialized_column_changed(attribute_name : String)
      if attribute_name == {{ name.id.stringify }}
        @_{{ name.id }}_modified = true
      else
        super
      end
    end
  end
end
