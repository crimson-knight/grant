require "json"
require "uuid"
require "uuid/json"
require "uuid/yaml"

module Grant::Columns
  alias SupportedArrayTypes = Array(String) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Float32) | Array(Float64) | Array(Bool) | Array(UUID)
  alias Type = DB::Any | SupportedArrayTypes | UUID

  # Virtual attributes can participate in model mass assignment without
  # becoming database columns. Encrypted attributes register their setters
  # here so `new(email: ...)` and `set_attributes` use the same perimeter.
  module VirtualAttributeRegistry
    @@setters = {} of Tuple(String, String) => Proc(Grant::Base, Type, Nil)

    def self.register(model_name : String, attribute_name : String, setter : Proc(Grant::Base, Type, Nil)) : Nil
      @@setters[{model_name, attribute_name}] = setter
    end

    def self.assign(record : Grant::Base, attribute_name : String, value : Type) : Bool
      if setter = @@setters[{record.class.name, attribute_name}]?
        setter.call(record, value)
        true
      else
        false
      end
    end

    def self.string_value(value : Type) : String?
      case value
      when Nil    then nil
      when String then value
      else             value.to_s
      end
    end
  end

  module ClassMethods
    # All fields
    def fields : Array(String)
      {% begin %}
        {% columns = @type.instance_vars.select(&.annotation(Grant::Column)).map(&.name.stringify) %}
        {{columns.empty? ? "[] of String".id : columns}}
      {% end %}
    end

    # Columns minus the PK
    def content_fields : Array(String)
      {% begin %}
        {% columns = @type.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && !ann[:primary] }.map(&.name.stringify) %}
        {{columns.empty? ? "[] of String".id : columns}}
      {% end %}
    end

    # Returns the list of column names declared read-only via `attr_readonly`.
    #
    # Read-only columns may be set when a record is created. Direct writes via
    # `update_columns` reject them; normal updates omit them.
    def readonly_attributes : Array(String)
      [] of String
    end
  end

  def content_values : Array(Grant::Columns::Type)
    parsed_params = [] of Type
    {% for column in @type.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && !ann[:primary] } %}
      {% ann = column.annotation(Grant::Column) %}
      parsed_params << {% if ann[:converter] %} {{ann[:converter]}}.to_db {{column.name.id}} {% else %} {{column.name.id}} {% end %}
    {% end %}
    parsed_params
  end

  # Captures typed column values for transaction rollback. The tuple keeps
  # custom converter values at their application types.
  protected def capture_column_values_for_transaction
    {% begin %}
    Tuple.new(
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        @{{column.id}},
      {% end %}
    )
    {% end %}
  end

  # Restores a tuple produced by `capture_column_values_for_transaction`.
  protected def restore_column_values_for_transaction(values)
    {% for column, index in @type.instance_vars.select(&.annotation(Grant::Column)) %}
      @{{column.id}} = values[{{index}}]
    {% end %}
  end

  # Consumes the result set to set self's property values.
  def from_rs(result : DB::ResultSet) : Nil
    {% begin %}
      result.column_names.each do |col|
        case col
        {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
          {% ann = column.annotation(Grant::Column) %}
          when {{column.name.stringify}}
            @{{column.id}} = {% if ann[:converter] %}
              {{ann[:converter]}}.from_rs result
            {% else %}
              value = Grant::Type.from_rs(result, {{ann[:nilable] ? column.type : column.type.union_types.reject { |t| t == Nil }.first}}, self.class.adapter)

              {% if column.has_default_value? && !column.default_value.nil? %}
                return {{column.default_value}} if value.nil?
              {% end %}

              value
            {% end %}
        {% end %}
        else
          # Not a mapped column: a computed `select` expression. Read it so the
          # columns after it stay aligned, and keep it as an extra attribute.
          value = result.read
          store_extra_attribute(col, value.is_a?(Grant::Columns::Type) ? value : value.to_s)
        end
      end
    {% end %}

    # Capture original attributes for dirty tracking if not a new record
    if !new_record?
      ensure_dirty_tracking_initialized
      dirty_tracking_hashes[0].clear
      dirty_tracking_hashes[1].clear
      {% for column in @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) } %}
        {% column_name = column.name.id.stringify %}
        {% ann = column.annotation(Grant::Column) %}
        # Convert value for storage if there's a converter
        {% if ann[:converter] %}
          dirty_tracking_hashes[0][{{column_name}}] = {{ann[:converter]}}.to_db(@{{column.name.id}}).as(Grant::Base::DirtyValue)
        {% else %}
          # Store the raw value for dirty tracking
          raw_value = @{{column.name.id}}
          dirty_tracking_hashes[0][{{column_name}}] = baseline_dirty_value({{column_name}}, raw_value.is_a?(Grant::Base::DirtyValue) ? raw_value : raw_value.to_s.as(Grant::Base::DirtyValue))
        {% end %}
      {% end %}
    end
  end

  # Defines a column *decl* with the given *options*.
  macro column(decl, **options)
    {% type = decl.type %}
    {% not_nilable_type = type.is_a?(Path) ? type.resolve : (type.is_a?(Union) ? type.types.reject(&.resolve.nilable?).first : (type.is_a?(Generic) ? type.resolve : type)) %}

    # Raise an exception if the delc type has more than 2 union types or if it has 2 types without nil
    # This prevents having a column typed to String | Int32 etc.
    {% if type.is_a?(Union) && (type.types.size > 2 || (type.types.size == 2 && !type.types.any?(&.resolve.nilable?))) %}
      {% raise "The column #{@type.name}##{decl.var} cannot consist of a Union with a type other than `Nil`." %}
    {% end %}

    {% column_type = (options[:column_type] && !options[:column_type].nil?) ? options[:column_type] : nil %}
    {% converter = (options[:converter] && !options[:converter].nil?) ? options[:converter] : nil %}
    # A JSON::Any column stores a JSON document: a native jsonb column on
    # PostgreSQL and JSON text elsewhere. No converter needs to be declared.
    {% converter = "Grant::Converters::JsonDocument".id if converter == nil && not_nilable_type.resolve == JSON::Any %}
    {% primary = (options[:primary] && !options[:primary].nil?) ? options[:primary] : false %}
    # An explicit `auto:` on a primary key wins. Without one, only integer and
    # UUID keys default to `auto: true`, since only they can be generated on
    # insert; any other key type (a String slug, say) defaults to `auto: false`.
    {% auto_generatable = not_nilable_type.resolve < Int || not_nilable_type.resolve == UUID %}
    {% auto = primary && (options[:auto] == nil ? auto_generatable : options[:auto]) %}

    {% nilable = (type.is_a?(Path) ? type.resolve.nilable? : (type.is_a?(Union) ? type.types.any?(&.resolve.nilable?) : (type.is_a?(Generic) ? type.resolve.nilable? : type.nilable?))) %}

    # ── Per-target column gating ───────────────────────────────────────────────
    # `targets:` restricts a column to one or more build targets. The active
    # target is the top-level `GRANT_COMPILE_TARGET` constant, set by
    # `require "grant/target/<name>"` (or by the app directly) BEFORE models
    # expand — there is no `-D` flag. When the active target is NOT among
    # `targets:`, the column is compiled out entirely (no ivar, accessors,
    # (de)serialization, or field-list entry) — it does not exist on that target,
    # at zero runtime cost. No `targets:`, or no target set at all, ⇒ present on
    # every target (the shared sync columns; the default/untargeted build keeps
    # every column).
    {% targets = (options[:targets] && !options[:targets].nil?) ? options[:targets] : nil %}

    # Read the active build target via the top-level namespace, nil-safe: an
    # untargeted build (constant absent) yields `nil`, so every gated column is
    # emitted. (`@top_level.has_constant?` / `.constant` — verified against the
    # compiler; see docs/compile_target_adapters.md.)
    {% active_target = @top_level.has_constant?("GRANT_COMPILE_TARGET") ? @top_level.constant("GRANT_COMPILE_TARGET") : nil %}

    {% if targets != nil %}
      # A column's identity (and especially the primary / sync key) must be the
      # same on every target so rows can be synchronised. Gating the primary key
      # would make it absent on some targets — forbidden.
      {% if primary %}
        {% raise "The primary key column #{@type.name}##{decl.var} cannot be gated with `targets:`. " \
                 "Primary and sync-key columns must be present on every build target." %}
      {% end %}

      {% unless targets.is_a?(ArrayLiteral) %}
        {% raise "The column #{@type.name}##{decl.var} `targets:` option must be an array of symbols, e.g. targets: [:web, :mobile]." %}
      {% end %}

      # Emit iff no target is set (untargeted build → keep everything) OR the
      # active target is one of this column's `targets`.
      {% emit = (active_target == nil) || targets.includes?(active_target) %}
    {% else %}
      # Ungated columns are present on every target (including the default build
      # where no target constant is set).
      {% emit = true %}
    {% end %}

    {% if emit %}
    @[Grant::Column(column_type: {{column_type}}, converter: {{converter}}, auto: {{auto}}, primary: {{primary}}, nilable: {{nilable}}, setter_type: {{not_nilable_type}}, null: {{options[:null]}}, limit: {{options[:limit]}}, precision: {{options[:precision]}}, scale: {{options[:scale]}}, comment: {{options[:comment]}}, collation: {{options[:collation]}}, default_sql: {{options[:default_sql]}}, uuid_version: {{options[:uuid_version]}})]
    @{{decl.var}} : {{decl.type}}? {% unless decl.value.is_a? Nop %} = {{decl.value}} {% end %}

    # The value assigned by mass assignment before conversion, when it
    # differed from the converted value; otherwise the current value.
    def {{decl.var.id}}_before_type_cast : Grant::Columns::Type
      attribute_before_type_cast({{decl.var.stringify}})
    end

    def will_save_change_to_{{decl.var.id}}? : Bool
      will_save_change_to_attribute?({{decl.var.stringify}})
    end

    def will_save_change_to_{{decl.var.id}}?(*, from) : Bool
      will_save_change_to_attribute?({{decl.var.stringify}}, from: from)
    end

    def will_save_change_to_{{decl.var.id}}?(*, to) : Bool
      will_save_change_to_attribute?({{decl.var.stringify}}, to: to)
    end

    def will_save_change_to_{{decl.var.id}}?(*, from, to) : Bool
      will_save_change_to_attribute?({{decl.var.stringify}}, from: from, to: to)
    end

    # Thin delegators to the name-keyed methods in `Grant::Dirty`.
    def saved_change_to_{{decl.var.id}}?(*, from = Grant::Dirty::UNFILTERED, to = Grant::Dirty::UNFILTERED) : Bool
      saved_change_to_attribute?({{decl.var.stringify}}, from: from, to: to)
    end

    def saved_change_to_{{decl.var.id}} : Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue)?
      saved_change_to_attribute({{decl.var.stringify}})
    end

    def {{decl.var.id}}_previously_changed?(*, from = Grant::Dirty::UNFILTERED, to = Grant::Dirty::UNFILTERED) : Bool
      saved_change_to_attribute?({{decl.var.stringify}}, from: from, to: to)
    end

    def {{decl.var.id}}_previously_was : Grant::Base::DirtyValue
      attribute_previously_was({{decl.var.stringify}})
    end

    def {{decl.var.id}}_in_database : Grant::Base::DirtyValue
      attribute_in_database({{decl.var.stringify}})
    end

    def {{decl.var.id}}_change_to_be_saved : Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue)?
      attribute_change_to_be_saved({{decl.var.stringify}})
    end

    def restore_{{decl.var.id}}! : Nil
      restore_attribute!({{decl.var.stringify}})
    end

    def {{decl.var.id}}_will_change! : Nil
      attribute_will_change!({{decl.var.stringify}})
    end

    # Assignment hook applied by the setter (see `normalizes`).
    private def __assign_hook_{{decl.var.id}}(value)
      value
    end

    {% if nilable || primary %}
      def {{decl.var.id}}=(value : {{not_nilable_type}}?)
        __guard_readonly_attribute!({{decl.var.stringify}})
        # `normalizes` overrides this hook; unaffected columns pay an inlined identity call.
        value = __assign_hook_{{decl.var.id}}(value)
        # Dirty tracking compares assignments against the initialized baseline.
        ensure_dirty_tracking_initialized

        # Capture original value if not already captured
        if !dirty_tracking_hashes[0].has_key?({{decl.var.stringify}})
          {% if converter %}
            dirty_tracking_hashes[0][{{decl.var.stringify}}] = {{converter}}.to_db(@{{decl.var.id}}).as(Grant::Base::DirtyValue)
          {% else %}
            old_value = @{{decl.var.id}}
            dirty_tracking_hashes[0][{{decl.var.stringify}}] = old_value.is_a?(Grant::Base::DirtyValue) ? old_value : old_value.to_s.as(Grant::Base::DirtyValue)
          {% end %}
        end

        # Compare converted values when the column has a converter.
        {% if converter %}
          old_db_value = {{converter}}.to_db(@{{decl.var.id}}).as(Grant::Base::DirtyValue)
          new_db_value = {{converter}}.to_db(value).as(Grant::Base::DirtyValue)
        {% else %}
          old_value = @{{decl.var.id}}
          old_db_value = old_value.is_a?(Grant::Base::DirtyValue) ? old_value : old_value.to_s.as(Grant::Base::DirtyValue)
          new_db_value = value.is_a?(Grant::Base::DirtyValue) ? value : value.to_s.as(Grant::Base::DirtyValue)
        {% end %}

        if old_db_value != new_db_value
          original = dirty_tracking_hashes[0][{{decl.var.stringify}}]
          if original == new_db_value
            dirty_tracking_hashes[1].delete({{decl.var.stringify}})
          else
            dirty_tracking_hashes[1][{{decl.var.stringify}}] = {original, new_db_value}
          end
        end

        discard_before_type_cast({{decl.var.stringify}})
        @{{decl.var.id}} = value
      end

      def {{decl.var.id}} : {{not_nilable_type}}?
        @{{decl.var}}
      end

      # Returns the raw nullable value without asserting presence. This is
      # useful while building a new record (for example, when prefilling a
      # form) even when the persisted column is declared non-nilable.
      def {{decl.var.id}}? : {{not_nilable_type}}?
        @{{decl.var}}
      end

      def {{decl.var.id}}! : {{not_nilable_type}}
        raise NilAssertionError.new {{@type.name.stringify}} + "#" + {{decl.var.stringify}} + " cannot be nil" if @{{decl.var}}.nil?
        @{{decl.var}}.not_nil!
      end
      
      # Dirty tracking methods
      
      # Returns true if the {{decl.var.id}} attribute has been changed.
      #
      # This is a convenience method equivalent to `attribute_changed?({{decl.var.stringify}})`.
      #
      # ```
      # user.{{decl.var.id}} = "new value"
      # user.{{decl.var.id}}_changed? # => true
      # ```
      def {{decl.var.id}}_changed? : Bool
        refresh_dirty
        ensure_dirty_tracking_initialized
        dirty_tracking_hashes[1].has_key?({{decl.var.stringify}})
      end
      
      # Returns the original value of {{decl.var.id}} before it was changed.
      #
      # If the attribute hasn't changed, returns the current value.
      # This is a convenience method equivalent to `attribute_was({{decl.var.stringify}})`.
      #
      # ```
      # original_value = user.{{decl.var.id}}
      # user.{{decl.var.id}} = "new value"
      # user.{{decl.var.id}}_was # => original_value
      # ```
      def {{decl.var.id}}_was : {{not_nilable_type}}?
        refresh_dirty
        ensure_dirty_tracking_initialized
        if dirty_tracking_hashes[1].has_key?({{decl.var.stringify}})
          dirty_tracking_hashes[1][{{decl.var.stringify}}][0].as({{not_nilable_type}}?)
        else
          @{{decl.var.id}}
        end
      end
      
      # Returns a tuple of the original and new values if {{decl.var.id}} has changed.
      #
      # Returns nil if the attribute hasn't changed.
      #
      # ```
      # user.{{decl.var.id}} # => "old value"
      # user.{{decl.var.id}} = "new value"
      # user.{{decl.var.id}}_change # => {"old value", "new value"}
      # ```
      def {{decl.var.id}}_change : Tuple({{not_nilable_type}}?, {{not_nilable_type}}?)?
        refresh_dirty
        ensure_dirty_tracking_initialized
        if change = dirty_tracking_hashes[1][{{decl.var.stringify}}]?
          {change[0].as({{not_nilable_type}}?), change[1].as({{not_nilable_type}}?)}
        end
      end
      
      # Returns the value of {{decl.var.id}} before the last save.
      #
      # If the attribute wasn't changed in the last save, returns current value.
      #
      # ```
      # user.{{decl.var.id}} = "new value"
      # user.save
      # user.{{decl.var.id}}_before_last_save # => "old value"
      # ```
      def {{decl.var.id}}_before_last_save : {{not_nilable_type}}?
        ensure_dirty_tracking_initialized
        if dirty_tracking_hashes[2].has_key?({{decl.var.stringify}})
          dirty_tracking_hashes[2][{{decl.var.stringify}}][0].as({{not_nilable_type}}?)
        else
          @{{decl.var.id}}
        end
      end
    {% else %}
      def {{decl.var.id}}=(value : {{type.id}})
        __guard_readonly_attribute!({{decl.var.stringify}})
        # `normalizes` overrides this hook; unaffected columns pay an inlined identity call.
        value = __assign_hook_{{decl.var.id}}(value)
        # Dirty tracking compares assignments against the initialized baseline.
        ensure_dirty_tracking_initialized

        # Capture original value if not already captured.
        if !dirty_tracking_hashes[0].has_key?({{decl.var.stringify}})
          {% if converter %}
            dirty_tracking_hashes[0][{{decl.var.stringify}}] = {{converter}}.to_db(@{{decl.var.id}}).as(Grant::Base::DirtyValue)
          {% else %}
            old_value = @{{decl.var.id}}
            dirty_tracking_hashes[0][{{decl.var.stringify}}] = old_value.is_a?(Grant::Base::DirtyValue) ? old_value : old_value.to_s.as(Grant::Base::DirtyValue)
          {% end %}
        end

        # Compare converted values when the column has a converter.
        {% if converter %}
          old_db_value = {{converter}}.to_db(@{{decl.var.id}}).as(Grant::Base::DirtyValue)
          new_db_value = {{converter}}.to_db(value).as(Grant::Base::DirtyValue)
        {% else %}
          old_value = @{{decl.var.id}}
          old_db_value = old_value.is_a?(Grant::Base::DirtyValue) ? old_value : old_value.to_s.as(Grant::Base::DirtyValue)
          new_db_value = value.is_a?(Grant::Base::DirtyValue) ? value : value.to_s.as(Grant::Base::DirtyValue)
        {% end %}

        if old_db_value != new_db_value
          original = dirty_tracking_hashes[0][{{decl.var.stringify}}]
          if original == new_db_value
            dirty_tracking_hashes[1].delete({{decl.var.stringify}})
          else
            dirty_tracking_hashes[1][{{decl.var.stringify}}] = {original, new_db_value}
          end
        end

        discard_before_type_cast({{decl.var.stringify}})
        @{{decl.var.id}} = value
      end

      def {{decl.var.id}} : {{type.id}}
        raise NilAssertionError.new {{@type.name.stringify}} + "#" + {{decl.var.stringify}} + " cannot be nil" if @{{decl.var}}.nil?
        @{{decl.var}}.not_nil!
      end

      # Returns the raw nullable value without asserting presence. A new model
      # may not have received this required attribute yet.
      def {{decl.var.id}}? : {{type.id}}?
        @{{decl.var}}
      end
      
      # Dirty tracking methods
      
      # Returns true if the {{decl.var.id}} attribute has been changed.
      #
      # This is a convenience method equivalent to `attribute_changed?({{decl.var.stringify}})`.
      #
      # ```
      # user.{{decl.var.id}} = "new value"
      # user.{{decl.var.id}}_changed? # => true
      # ```
      def {{decl.var.id}}_changed? : Bool
        refresh_dirty
        ensure_dirty_tracking_initialized
        dirty_tracking_hashes[1].has_key?({{decl.var.stringify}})
      end
      
      # Returns the original value of {{decl.var.id}} before it was changed.
      #
      # If the attribute hasn't changed, returns the current value.
      # This is a convenience method equivalent to `attribute_was({{decl.var.stringify}})`.
      #
      # ```
      # original_value = user.{{decl.var.id}}
      # user.{{decl.var.id}} = "new value"
      # user.{{decl.var.id}}_was # => original_value
      # ```
      def {{decl.var.id}}_was : {{type.id}}
        refresh_dirty
        ensure_dirty_tracking_initialized
        if dirty_tracking_hashes[1].has_key?({{decl.var.stringify}})
          dirty_tracking_hashes[1][{{decl.var.stringify}}][0].as({{type.id}})
        else
          @{{decl.var.id}}.not_nil!
        end
      end

      # Returns a tuple of the original and new values if {{decl.var.id}} has changed.
      #
      # Returns nil if the attribute hasn't changed.
      #
      # ```
      # user.{{decl.var.id}} # => "old value"
      # user.{{decl.var.id}} = "new value"
      # user.{{decl.var.id}}_change # => {"old value", "new value"}
      # ```
      def {{decl.var.id}}_change : Tuple({{type.id}}, {{type.id}})?
        refresh_dirty
        ensure_dirty_tracking_initialized
        if change = dirty_tracking_hashes[1][{{decl.var.stringify}}]?
          {change[0].as({{type.id}}), change[1].as({{type.id}})}
        end
      end
      
      # Returns the value of {{decl.var.id}} before the last save.
      #
      # If the attribute wasn't changed in the last save, returns current value.
      #
      # ```
      # user.{{decl.var.id}} = "new value"
      # user.save
      # user.{{decl.var.id}}_before_last_save # => "old value"
      # ```
      def {{decl.var.id}}_before_last_save : {{type.id}}
        ensure_dirty_tracking_initialized
        if dirty_tracking_hashes[2].has_key?({{decl.var.stringify}})
          dirty_tracking_hashes[2][{{decl.var.stringify}}][0].as({{type.id}})
        else
          @{{decl.var.id}}.not_nil!
        end
      end
    {% end %}
    {% end %}
  end

  # include created_at and updated_at that will automatically be updated
  macro timestamps
    column created_at : Time?
    column updated_at : Time?
  end

  def to_h
    fields = {{"Hash(String, Union(#{@type.instance_vars.select(&.annotation(Grant::Column)).map(&.type.id).splat})).new".id}}

    {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
      {% nilable = (column.type.is_a?(Path) ? column.type.resolve.nilable? : (column.type.is_a?(Union) ? column.type.types.any?(&.resolve.nilable?) : (column.type.is_a?(Generic) ? column.type.resolve.nilable? : column.type.nilable?))) %}

      begin
      {% if column.type.id == Time.id %}
        fields["{{column.name}}"] = {{column.name.id}}.try(&.in(Grant.settings.default_timezone).to_s(Grant::DATETIME_FORMAT))
      {% elsif column.type.id == Slice.id %}
        fields["{{column.name}}"] = {{column.name.id}}.try(&.to_s(""))
      {% else %}
        fields["{{column.name}}"] = {{column.name.id}}
      {% end %}
      rescue ex : NilAssertionError
        {% if nilable %}
        fields["{{column.name}}"] = nil
        {% end %}
      end
    {% end %}

    fields
  end

  def set_attributes(hash : Hash(String | Symbol, T)) : self forall T
    if self.class.has_attribute_aliases?
      hash = hash.transform_keys { |key| self.class.resolve_attribute_alias(key.to_s).as(String | Symbol) }
    end

    {% for column in @type.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && (!ann[:primary] || (ann[:primary] && ann[:auto] == false)) } %}
      {% ann = column.annotation(Grant::Column) %}
      {% if ann[:nilable] == true %}
        {% setter_type = column.type %}
      {% else %}
        {% setter_type = ann[:setter_type] %}
      {% end %}
      if hash.has_key?({{column.stringify}})
        begin
          val = Grant::Type.convert_type hash[{{column.stringify}}], {{setter_type}}
        rescue ex : ArgumentError
          error =  Grant::ConversionError.new({{column.name.stringify}}, ex.message)
        end

        if !val.is_a? {{setter_type}}
          error = Grant::ConversionError.new({{column.name.stringify}}, "Expected {{column.id}} to be {{setter_type}} but got #{typeof(val)}.")
        else
          self.{{column}} = val
          # Keep the raw input only when conversion changed it.
          raw_input = hash[{{column.stringify}}]
          if raw_input.is_a?(Grant::Columns::Type) && raw_input != val
            capture_before_type_cast({{column.stringify}}, raw_input)
          end
        end

        errors << error if error
      end
    {% end %}
    hash.each do |attribute_name, value|
      Grant::AssociationRegistry.assign(self, attribute_name.to_s, value)
    end
    self
  end

  # Converts and assigns one model column during value-object mass
  # assignment. Keeping this at the column boundary applies both the declared
  # conversion and the generated dirty-tracking setter.
  def assign_mass_assignment_column(attribute_name : String, value : Grant::Columns::Type) : Nil
    attribute_name = self.class.resolve_attribute_alias(attribute_name)
    return if Grant::Columns::VirtualAttributeRegistry.assign(self, attribute_name, value)

    {% begin %}
    case attribute_name
    {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
      {% ann = column.annotation(Grant::Column) %}
      when {{column.name.stringify}}
        {% if ann[:nilable] == true %}
          {% setter_type = column.type %}
        {% else %}
          {% setter_type = ann[:setter_type] %}
        {% end %}
        begin
          converted_value = Grant::Type.convert_type(value, {{setter_type}})
          if converted_value.is_a?({{setter_type}})
            self.{{column.name.id}} = converted_value
            capture_before_type_cast({{column.name.stringify}}, value) if value != converted_value
          else
            errors << Grant::ConversionError.new({{column.name.stringify}}, "Expected {{column.name.id}} to be {{setter_type}} but got #{typeof(converted_value)}.")
          end
        rescue ex : ArgumentError
          errors << Grant::ConversionError.new({{column.name.stringify}}, ex.message)
        end
    {% end %}
    else
      if encrypted_attribute = self.class.encrypted_attributes[attribute_name]?
        case value
        when String
          encrypted_attribute.assign(self, value)
        when Nil
          encrypted_attribute.assign(self, nil)
        else
          errors << Grant::ConversionError.new(attribute_name, "Expected #{attribute_name} to be String? but got #{typeof(value)}.")
        end
      else
        raise "Cannot write attribute #{attribute_name}, invalid attribute"
      end
    end
    {% end %}
  end

  def read_attribute(attribute_name : Symbol | String) : Type
    {% begin %}
      case attribute_name.to_s
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        {% ann = column.annotation(Grant::Column) %}
      when "{{ column.name }}"
        {% if ann[:converter] %}
          {{ann[:converter]}}.to_db @{{column.name.id}}
        {% else %}
          @{{ column.name.id }}
        {% end %}
      {% end %}
      else
        raise "Cannot read attribute #{attribute_name}, invalid attribute"
      end
    {% end %}
  end

  def write_attribute(attribute_name : String | Symbol, value : Grant::Columns::Type)
    {% begin %}
      case attribute_name.to_s
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        when {{column.name.stringify}}
          if value.is_a?({{column.type}})
            self.{{column.name.id}} = value
          else
            raise "Cannot write attribute #{attribute_name}: expected {{column.type}} but got #{value.class}"
          end
      {% end %}
      else
        raise "Cannot write attribute #{attribute_name}, invalid attribute"
      end
    {% end %}
  end

  def primary_key_value
    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
      {{primary_key.id}}
    {% end %}
  end

  # Get all primary key columns for composite key support
  def self.primary_key_columns : Array(String)
    {% begin %}
      {% primary_keys = @type.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] }.map(&.name.stringify) %}
      {{primary_keys.empty? ? "[] of String".id : primary_keys}}
    {% end %}
  end

  # Get primary key values as a hash for composite key support
  def primary_key_values : Hash(String, Grant::Columns::Type)
    values = {} of String => Grant::Columns::Type
    {% for column in @type.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      values[{{column.name.stringify}}] = {{column.name.id}}
    {% end %}
    values
  end

  # Check if model has composite primary key
  def self.composite_primary_key? : Bool
    primary_key_columns.size > 1
  end

  # Capture current values as original attributes after save
  protected def capture_original_attributes
    ensure_dirty_tracking_initialized
    {% for column in @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) } %}
      {% column_name = column.name.id.stringify %}
      {% ann = column.annotation(Grant::Column) %}
      # Convert value for storage if there's a converter
      {% if ann[:converter] %}
        dirty_tracking_hashes[0][{{column_name}}] = {{ann[:converter]}}.to_db(@{{column.name.id}}).as(Grant::Base::DirtyValue)
      {% else %}
        # Store the raw value for dirty tracking
        raw_value = @{{column.name.id}}
        dirty_tracking_hashes[0][{{column_name}}] = baseline_dirty_value({{column_name}}, raw_value.is_a?(Grant::Base::DirtyValue) ? raw_value : raw_value.to_s.as(Grant::Base::DirtyValue))
      {% end %}
    {% end %}
  end
end
