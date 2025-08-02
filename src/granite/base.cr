require "./collection"
require "./association_collection"
require "./loaded_association_collection"
require "./associations"
require "./callbacks"
require "./columns"
require "./columns_helpers"
require "./query/executors/base"
require "./query/**"
require "./query_extensions"
require "./enum_attributes"
require "./convenience_methods"
require "./settings"
require "./table"
require "./transactions"
require "./validators"
require "./validators/**"
require "./validation_helpers/**"
require "./migrator"
require "./select"
require "./version"
require "./connections"
require "./integrators"
require "./converters"
require "./type"
require "./connection_management"
require "./eager_loading"
require "./association_loader"
require "./commit_callbacks"
require "./scoping"
require "./attribute_api"
require "./logging"
require "./query_analysis"
require "./composite_primary_key"
require "./secure_token"
require "./signed_id"
require "./token_for"
require "./serialized_column"

# Granite::Base is the base class for your model objects.
abstract class Granite::Base
  # Dirty tracking storage - using a union of all possible types
  # We use a broad union type to handle all column types including enums
  alias DirtyValue = Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Time | UUID | Slice(UInt8) | Array(String) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Float32) | Array(Float64) | Array(Bool) | Array(UUID)
  include Associations
  include Callbacks
  include Columns
  include Tables
  include Transactions
  include Validators
  include ValidationHelpers
  include Migrator
  include Select
  include Querying
  include EagerLoading
  include CommitCallbacks
  include Scoping

  include ConnectionManagement
  include AttributeApi
  include SerializedColumn
  
  # Make secure token macros available
  macro has_secure_token(name, length = 24, alphabet = :base58)
    Granite::SecureToken.has_secure_token({{ name }}, {{ length }}, {{ alphabet }})
  end
  
  
  # Auto-register class for polymorphic associations will be handled in the main inherited macro

  extend Columns::ClassMethods
  extend Tables::ClassMethods
  extend Granite::Migrator::ClassMethods

  extend Querying::ClassMethods
  extend Query::BuilderMethods
  extend Granite::Transactions::ClassMethods
  extend Integrators
  extend Select
  extend EagerLoading::ClassMethods
  extend Scoping::ClassMethods

  macro inherited
    protected class_getter select_container : Container = Container.new(table_name: table_name, fields: fields)
    
    # Auto-register for polymorphic associations
    Granite::Polymorphic.register_polymorphic_type({{@type.name.stringify}}, {{@type}})
    
    # Make generates_token_for available
    macro generates_token_for(purpose, expires_in = nil, &block)
      Granite::TokenFor.generates_token_for(\{{ purpose }}, \{{ expires_in }}) do
        \{{ block.body }}
      end
    end

    # Returns true if this object hasn't been saved yet.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    disable_granite_docs? property? new_record : Bool = true

    # Returns true if this object has been destroyed.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    disable_granite_docs? getter? destroyed : Bool = false

    # Returns true if the record is persisted.
    disable_granite_docs? def persisted?
      !(new_record? || destroyed?)
    end
    
    # Dirty tracking storage - using a union of all possible types
    # We use a broad union type to handle all column types including enums
    
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @original_attributes : Hash(String, DirtyValue)?
    
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @changed_attributes : Hash(String, Tuple(DirtyValue, DirtyValue))?
    
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @previous_changes : Hash(String, Tuple(DirtyValue, DirtyValue))?
    
    # Ensure dirty tracking hashes are initialized
    private def ensure_dirty_tracking_initialized
      @original_attributes ||= {} of String => DirtyValue
      @changed_attributes ||= {} of String => Tuple(DirtyValue, DirtyValue)
      @previous_changes ||= {} of String => Tuple(DirtyValue, DirtyValue)
    end
    
    # Hook for JSON/YAML deserialization
    def after_initialize
      ensure_dirty_tracking_initialized
    end

    include JSON::Serializable
    include YAML::Serializable
    
    macro finished
      disable_granite_docs? def initialize(**args : Granite::Columns::Type)
        ensure_dirty_tracking_initialized
        set_attributes(args.to_h.transform_keys(&.to_s))
        __after_initialize
      end

      disable_granite_docs? def initialize(args : Granite::ModelArgs)
        ensure_dirty_tracking_initialized
        set_attributes(args.transform_keys(&.to_s))
        __after_initialize
      end

      disable_granite_docs? def initialize
        ensure_dirty_tracking_initialized
        __after_initialize
      end
    end

    # Connection handling is automatic now
    before_save { self.class.mark_write_operation }
    before_destroy { self.class.mark_write_operation }
    after_save :clear_dirty_state
    
    # Dirty tracking API methods
    
    # Returns true if any attributes have been changed since the last save.
    #
    # ```
    # user = User.find!(1)
    # user.changed? # => false
    # 
    # user.name = "New Name"
    # user.changed? # => true
    # 
    # user.save
    # user.changed? # => false
    # ```
    def changed? : Bool
      ensure_dirty_tracking_initialized
      !@changed_attributes.not_nil!.empty?
    end
    
    # Returns a hash of all changed attributes with their original and new values.
    #
    # The hash keys are attribute names, and values are tuples of `{original_value, new_value}`.
    #
    # ```
    # user = User.find!(1)
    # user.name # => "John"
    # user.age # => 25
    # 
    # user.name = "Jane"
    # user.age = 26
    # 
    # user.changes
    # # => {"name" => {"John", "Jane"}, "age" => {25, 26}}
    # ```
    def changes
      ensure_dirty_tracking_initialized
      @changed_attributes.not_nil!.dup
    end
    
    # Returns an array of names of attributes that have been changed.
    #
    # ```
    # user = User.find!(1)
    # user.name = "New Name"
    # user.email = "new@example.com"
    # 
    # user.changed_attributes # => ["name", "email"]
    # ```
    def changed_attributes
      ensure_dirty_tracking_initialized
      @changed_attributes.not_nil!.keys
    end
    
    # Returns the changes that were saved in the last save operation.
    #
    # This is useful for after_save callbacks to know what changed.
    #
    # ```
    # user = User.find!(1)
    # user.name = "New Name"
    # user.save
    # 
    # user.previous_changes # => {"name" => {"Old Name", "New Name"}}
    # user.changes # => {} (empty after save)
    # ```
    def previous_changes
      ensure_dirty_tracking_initialized
      @previous_changes.not_nil!.dup
    end
    
    # Alias for `previous_changes`. Returns the changes from the last save.
    #
    # This method provides Rails-compatible API.
    #
    # ```
    # user.saved_changes # => {"name" => {"Old Name", "New Name"}}
    # ```
    def saved_changes
      previous_changes
    end
    
    # Returns true if the specified attribute has been changed.
    #
    # ```
    # user = User.find!(1)
    # user.name = "New Name"
    # 
    # user.attribute_changed?("name")  # => true
    # user.attribute_changed?(:name)    # => true
    # user.attribute_changed?("email") # => false
    # ```
    def attribute_changed?(name : String | Symbol) : Bool
      ensure_dirty_tracking_initialized
      @changed_attributes.not_nil!.has_key?(name.to_s)
    end
    
    # Returns the original value of an attribute before it was changed.
    #
    # If the attribute hasn't changed, returns the current value.
    #
    # ```
    # user = User.find!(1)
    # user.name # => "John"
    # 
    # user.name = "Jane"
    # user.attribute_was("name") # => "John"
    # user.attribute_was(:email)  # => "john@example.com" (unchanged)
    # ```
    def attribute_was(name : String | Symbol)
      ensure_dirty_tracking_initialized
      name_str = name.to_s
      if @changed_attributes.not_nil!.has_key?(name_str)
        @changed_attributes.not_nil![name_str][0]
      else
        read_attribute(name_str)
      end
    end
    
    # Returns true if the specified attribute was changed in the last save.
    #
    # Useful in after_save callbacks to check what was changed.
    #
    # ```
    # after_save :send_email_if_email_changed
    # 
    # private def send_email_if_email_changed
    #   if saved_change_to_attribute?("email")
    #     # Send confirmation email
    #   end
    # end
    # ```
    def saved_change_to_attribute?(name : String | Symbol) : Bool
      ensure_dirty_tracking_initialized
      @previous_changes.not_nil!.has_key?(name.to_s)
    end
    
    # Returns the value of an attribute before the last save.
    #
    # If the attribute wasn't changed in the last save, returns current value.
    #
    # ```
    # user = User.find!(1)
    # user.name # => "John"
    # 
    # user.name = "Jane"
    # user.save
    # 
    # user.attribute_before_last_save("name") # => "John"
    # user.name = "Jim"
    # user.attribute_before_last_save("name") # => "John" (still from last save)
    # ```
    def attribute_before_last_save(name : String | Symbol)
      ensure_dirty_tracking_initialized
      name_str = name.to_s
      if @previous_changes.not_nil!.has_key?(name_str)
        @previous_changes.not_nil![name_str][0]
      else
        read_attribute(name_str)
      end
    end
    
    # Restores attributes to their original values.
    #
    # If specific attributes are provided, only those are restored.
    # If no attributes are provided, all changed attributes are restored.
    #
    # ```
    # user = User.find!(1)
    # original_name = user.name # => "John"
    # original_age = user.age   # => 25
    # 
    # user.name = "Jane"
    # user.age = 26
    # 
    # # Restore only name
    # user.restore_attributes(["name"])
    # user.name # => "John"
    # user.age  # => 26
    # 
    # # Restore all changes
    # user.restore_attributes
    # user.age # => 25
    # ```
    def restore_attributes(attributes : Array(String)? = nil)
      ensure_dirty_tracking_initialized
      attrs = attributes || @changed_attributes.not_nil!.keys
      
      # Temporarily store changed attributes to restore
      changes_to_restore = {} of String => {Granite::Columns::Type, Granite::Columns::Type}
      attrs.each do |attr|
        if change = @changed_attributes.not_nil![attr]?
          changes_to_restore[attr] = change
        end
      end
      
      # Clear the changes for the attributes being restored
      attrs.each do |attr|
        @changed_attributes.not_nil!.delete(attr)
      end
      
      # Restore the values using write_attribute
      changes_to_restore.each do |attr, change|
        write_attribute(attr, change[0])
        # Remove the change that write_attribute just added
        @changed_attributes.not_nil!.delete(attr)
      end
    end
    
    # Clear dirty state after save
    private def clear_dirty_state
      ensure_dirty_tracking_initialized
      @previous_changes = @changed_attributes.not_nil!.dup
      @changed_attributes.not_nil!.clear
      @original_attributes.not_nil!.clear
      @new_record = false
      
      # Capture current state as new originals
      capture_original_attributes
    end
    
    # This will be overridden in each model to capture all column values
    protected def capture_original_attributes
      # Implemented in each model via macro
    end
  end
end
