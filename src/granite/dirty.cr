module Granite::Dirty
  macro included
    # Track original attributes when loaded from database
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @original_attributes = {} of String => Granite::Columns::Type
    
    # Track changed attributes during the session
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @changed_attributes = {} of String => Tuple(Granite::Columns::Type, Granite::Columns::Type)
    
    # Track changes from the last save
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @previous_changes = {} of String => Tuple(Granite::Columns::Type, Granite::Columns::Type)
    
    # Override from_rs to capture original state
    def from_rs(result : DB::ResultSet) : Nil
      previous_def
      capture_original_attributes
    end
    
    # Override initialize to set up tracking for new records
    def initialize(**args)
      previous_def
      capture_original_attributes if persisted?
    end
    
    def initialize(args : Granite::ModelArgs)
      previous_def
      capture_original_attributes if persisted?
    end
    
    def initialize
      previous_def
      capture_original_attributes if persisted?
    end
  end
  
  # Capture the current state as original
  private def capture_original_attributes
    @original_attributes.clear
    @changed_attributes.clear
    
    {% for column in @type.instance_vars.select { |ivar| ivar.annotation(Granite::Column) } %}
      {% column_name = column.name.id.stringify %}
      @original_attributes[{{column_name}}] = @{{column.name.id}}.as(Granite::Columns::Type)
    {% end %}
  end
  
  # Track changes when attributes are set
  private def track_attribute_change(name : String, old_value : Granite::Columns::Type, new_value : Granite::Columns::Type)
    return if old_value == new_value
    
    if @original_attributes.has_key?(name)
      original = @original_attributes[name]
      if original == new_value
        # Reverting to original value
        @changed_attributes.delete(name)
      else
        @changed_attributes[name] = {original, new_value}
      end
    else
      @changed_attributes[name] = {old_value, new_value}
    end
  end
  
  # Check if a specific attribute has changed
  def attribute_changed?(name : String | Symbol) : Bool
    @changed_attributes.has_key?(name.to_s)
  end
  
  # Get the original value of an attribute
  def attribute_was(name : String | Symbol) : Granite::Columns::Type
    name_str = name.to_s
    if @changed_attributes.has_key?(name_str)
      @changed_attributes[name_str][0]
    else
      read_attribute(name_str)
    end
  end
  
  # Get the change for a specific attribute [old, new]
  def attribute_change(name : String | Symbol) : Tuple(Granite::Columns::Type, Granite::Columns::Type)?
    @changed_attributes[name.to_s]?
  end
  
  # Get all changes
  def changes : Hash(String, Tuple(Granite::Columns::Type, Granite::Columns::Type))
    @changed_attributes.dup
  end
  
  # Check if any attributes have changed
  def changed? : Bool
    !@changed_attributes.empty?
  end
  
  # Get list of changed attribute names
  def changed_attributes : Array(String)
    @changed_attributes.keys
  end
  
  # Get changes from the last save
  def previous_changes : Hash(String, Tuple(Granite::Columns::Type, Granite::Columns::Type))
    @previous_changes.dup
  end
  
  # Get saved changes (alias for previous_changes)
  def saved_changes : Hash(String, Tuple(Granite::Columns::Type, Granite::Columns::Type))
    previous_changes
  end
  
  # Check if attribute changed in the last save
  def saved_change_to_attribute?(name : String | Symbol) : Bool
    @previous_changes.has_key?(name.to_s)
  end
  
  # Get the value of an attribute before the last save
  def attribute_before_last_save(name : String | Symbol) : Granite::Columns::Type
    name_str = name.to_s
    if @previous_changes.has_key?(name_str)
      @previous_changes[name_str][0]
    else
      read_attribute(name_str)
    end
  end
  
  # Restore attributes to their original values
  def restore_attributes(attributes : Array(String)? = nil)
    attrs = attributes || @changed_attributes.keys
    
    attrs.each do |attr|
      if change = @changed_attributes[attr]?
        write_attribute(attr, change[0])
      end
    end
  end
  
  # Clear dirty state after successful save
  private def clear_dirty_state
    @previous_changes = @changed_attributes.dup
    @changed_attributes.clear
    capture_original_attributes
  end
  
  # Macro to generate dirty tracking for each column
  macro setup_dirty_tracking
    macro finished
      \{% for column in @type.instance_vars.select { |ivar| ivar.annotation(Granite::Column) } %}
      \{% column_name = column.name.id.stringify %}
      
      # Generate attribute_changed? method
      def \{{column.name.id}}_changed? : Bool
        attribute_changed?(\{{column_name}})
      end
      
      # Generate attribute_was method
      def \{{column.name.id}}_was : \{{column.type}}
        value = attribute_was(\{{column_name}})
        value.as(\{{column.type}}) if value
      end
      
      # Generate attribute_change method
      def \{{column.name.id}}_change : Tuple(\{{column.type}}, \{{column.type}})?
        if change = attribute_change(\{{column_name}})
          {change[0].as(\{{column.type}}), change[1].as(\{{column.type}})}
        end
      end
      
      # Generate attribute_before_last_save method
      def \{{column.name.id}}_before_last_save : \{{column.type}}
        value = attribute_before_last_save(\{{column_name}})
        value.as(\{{column.type}}) if value
      end
      
      # Override setter to track changes
      def \{{column.name.id}}=(value : \{{column.type}})
        old_value = @\{{column.name.id}}.as(Granite::Columns::Type)
        previous_def
        new_value = @\{{column.name.id}}.as(Granite::Columns::Type)
        track_attribute_change(\{{column_name}}, old_value, new_value)
      end
    \{% end %}
    end
  end
end