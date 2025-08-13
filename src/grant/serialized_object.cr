module Grant::SerializedObject
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_changed : Bool = false

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_parent : Grant::Base?

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_attribute_name : String?

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_original_values = {} of String => Tuple(String, String)

  def changed?
    @_changed
  end

  def mark_as_changed!
    @_changed = true
    # Notify parent if set
    if parent = @_parent
      if attribute_name = @_attribute_name
        # Use a method that exists on the parent
        if parent.responds_to?(:_mark_serialized_column_changed)
          parent._mark_serialized_column_changed(attribute_name)
        end
      end
    end
  end

  def reset_changes!
    @_changed = false
    @_original_values.clear
  end

  def _set_parent(parent : Grant::Base, attribute_name : String)
    @_parent = parent
    @_attribute_name = attribute_name
  end

  # Track a change
  def _track_change(property_name : String, old_value : String, new_value : String)
    @_original_values[property_name] = {old_value, new_value}
    mark_as_changed!
  end

  def changes
    @_original_values.dup
  end

  # Helper macro to add change tracking to properties
  macro track_changes_for(*properties)
    {% for prop in properties %}
      {% prop_name = prop.id.stringify %}
      
      # Getter is already defined by property declaration
      # Just define the custom setter
      def {{ prop.id }}=(value)
        old_val = @{{ prop.id }}
        if old_val != value
          _track_change({{ prop_name }}, old_val.to_s, value.to_s)
        end
        @{{ prop.id }} = value
      end
    {% end %}
  end
end