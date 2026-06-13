# Aggregate several columns into a single immutable value object, in the style of
# Rails' `composed_of`.
#
# `aggregation :address, Address, mapping: {...}` exposes a group of related
# columns (street, city, zip) as one `Address` struct. Reading `#address` builds
# the value object from the underlying columns (and caches it); assigning
# `#address = Address.new(...)` writes the object's parts back out to those
# columns. The columns themselves are declared for you as `String?` and converted
# at the boundary.
#
# This module is mixed into every `Grant::Base`, so `aggregation` is available on
# any model. The value object is typically an immutable `struct` with a matching
# constructor (or supply a custom `constructor:` proc).
#
# ```
# struct Address
#   getter street : String
#   getter city : String
#   getter zip : String
#
#   def initialize(@street, @city, @zip); end
# end
#
# class Customer < Grant::Base
#   column id : Int64, primary: true
#   aggregation :address, Address, mapping: {
#     address_street: :street,
#     address_city:   :city,
#     address_zip:    :zip,
#   }
# end
#
# c = Customer.new
# c.address = Address.new("1 Main St", "Springfield", "00001")
# c.@address_street     # => "1 Main St" (written through to the column)
# c.address.try(&.city) # => "Springfield" (rebuilt from columns)
# c.address_changed?    # => true
# ```
module Grant::ValueObjects
  # Compile-/run-time metadata describing one `aggregation` declaration: its name,
  # value-object class name, column⇒attribute mapping, and options. Returned by
  # the generated `.aggregations` introspection method; not constructed directly.
  class AggregationMeta
    getter name : String
    getter class_name : String
    getter mapping : Hash(String, Symbol)
    getter allow_nil : Bool
    getter has_custom_constructor : Bool

    # Builds metadata for an aggregation. Populated by the `aggregation` macro;
    # not intended to be constructed by hand.
    def initialize(@name : String, @class_name : String, @mapping : Hash(String, Symbol), @has_custom_constructor : Bool = false, @allow_nil : Bool = false)
    end
  end

  # Raised when a value object cannot be built or is invalid.
  class ValueObjectError < Exception
  end

  # Declares an aggregation named *name* that composes the mapped columns into a
  # *class_name* value object.
  #
  # *mapping* is a `{column_name: :attribute_name, ...}` `NamedTuple` linking each
  # backing column (declared for you as `String?`) to a constructor argument /
  # accessor of the value object. *class_name* defaults to the camelized *name*.
  #
  # For `aggregation :address, Address, mapping: {...}` this generates:
  #
  # * the backing columns (e.g. `address_street`, `address_city`, ... as `String?`);
  # * `#address : Address?` — builds (and caches) the value object from the
  #   columns; returns `nil` if a required column is `nil`;
  # * `#address=(value : Address?)` — writes the object's parts back to the columns
  #   (or `nil`s them all when assigned `nil`);
  # * `#address_changed? : Bool` and `#address_was : Address?` — dirty tracking;
  # * a model validation that surfaces the value object's own `validate` errors
  #   (when it defines one).
  #
  # Options: `allow_nil: true` lets the aggregation be entirely absent (all columns
  # `nil` ⇒ `#address` returns `nil` instead of failing); `constructor:` supplies a
  # `Proc` that receives the raw column strings and returns the value object (for
  # custom parsing/conversion) in place of the default named-argument constructor.
  #
  # ```
  # struct Money
  #   getter amount : Float64
  #   getter currency : String
  #
  #   def initialize(@amount, @currency = "USD"); end
  #
  #   def self.new(*, amount : String, currency : String) # string constructor
  #     new(amount.to_f64, currency)
  #   end
  # end
  #
  # class Account < Grant::Base
  #   column id : Int64, primary: true
  #   aggregation :balance, Money,
  #     mapping: {balance_amount: :amount, balance_currency: :currency},
  #     allow_nil: true
  # end
  #
  # a = Account.new
  # a.balance = Money.new(10.0, "USD")
  # a.balance.try(&.amount) # => 10.0
  # a.balance_changed?      # => true
  # ```
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
    class_getter _{{method_name}}_aggregation_meta = Grant::ValueObjects::AggregationMeta.new(
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
              instance.errors << Grant::Error.new(:{{method_name}}, "#{vo_error.field} #{vo_error.message}")
            end
            next false
          end
        end
        true
      rescue ex : Exception
        instance.errors << Grant::Error.new(:{{method_name}}, "is invalid: #{ex.message}")
        false
      end
    end
  end

  # Class-level value-object support, extended onto every `Grant::Base`. The
  # concrete aggregation methods are generated per model by the `aggregation`
  # macro and the `finished` hook below.
  module ClassMethods
    # This will be populated by each model
  end

  # Empty placeholder - aggregations method will be generated in the model's macro finished

  # Empty placeholder - methods will be generated in the combined macro finished

  # Macro to generate all value object methods
  macro finished
    # Dirty tracking for aggregations.
    # Declared nilable (with lazy initialization in `aggregation_changes` below)
    # rather than carrying a default value so that `YAML::Serializable` /
    # `JSON::Serializable`'s auto-generated deserialization initializer — included
    # on the abstract `Grant::Base` — does not report it as uninitialized for
    # `Grant::Base+`. See issues #39/#41.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @aggregation_changes : Hash(String, Tuple(String?, String?))?

    protected def aggregation_changes : Hash(String, Tuple(String?, String?))
      @aggregation_changes ||= {} of String => Tuple(String?, String?)
    end

    # Returns a `Hash(Symbol, AggregationMeta)` describing every aggregation
    # declared on this model, keyed by aggregation name. Useful for introspection
    # and tooling.
    #
    # ```crystal
    # Customer.aggregations.keys # => [:address]
    # ```
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
      aggregation_changes[name] = {old_str, new_str}
    end
    
    # Returns `true` if any backing column of the aggregation named *name* has
    # unsaved changes. Backs the generated per-aggregation `#<name>_changed?`
    # predicate.
    #
    # ```crystal
    # c.address_changed?               # generated wrapper
    # c.aggregation_changed?("address") # equivalent
    # ```
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
    
    # Returns the previous (pre-change) value of the aggregation named *name*, or
    # its current value if unchanged. Backs the generated `#<name>_was` accessor.
    def aggregation_was(name : String)
      if aggregation_changes.has_key?(name)
        aggregation_changes[name][0]
      else
        read_aggregation(name)
      end
    end
    
    # Returns the value object for the aggregation named *name* (the same result
    # as calling the generated `#<name>` getter), or `nil` for an unknown name.
    # Dynamic counterpart to the named getters.
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
    
    # Assigns *value* to the aggregation named *name* (the same as calling the
    # generated `#<name>=` setter), writing through to the backing columns.
    # Dynamic counterpart to the named setters.
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
    
    # Mass-assigns *args*, routing keys that name an aggregation through
    # `write_aggregation` (so a value object can be set directly) and all other
    # keys through the normal `write_attribute` path. Overrides the base
    # `set_attributes` to make value objects mass-assignable.
    def set_attributes(args : Grant::ModelArgs)
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
