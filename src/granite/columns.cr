require "json"
require "uuid"

module Granite::Columns
  alias SupportedArrayTypes = Array(String) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Float32) | Array(Float64) | Array(Bool) | Array(UUID)
  alias Type = DB::Any | SupportedArrayTypes | UUID

  module ClassMethods
    # All fields
    def fields : Array(String)
      {% begin %}
        {% columns = @type.instance_vars.select(&.annotation(Granite::Column)).map(&.name.stringify) %}
        {{columns.empty? ? "[] of String".id : columns}}
      {% end %}
    end

    # Columns minus the PK
    def content_fields : Array(String)
      {% begin %}
        {% columns = @type.instance_vars.select { |ivar| (ann = ivar.annotation(Granite::Column)) && !ann[:primary] }.map(&.name.stringify) %}
        {{columns.empty? ? "[] of String".id : columns}}
      {% end %}
    end
  end

  def content_values : Array(Granite::Columns::Type)
    parsed_params = [] of Type
    {% for column in @type.instance_vars.select { |ivar| (ann = ivar.annotation(Granite::Column)) && !ann[:primary] } %}
      {% ann = column.annotation(Granite::Column) %}
      parsed_params << {% if ann[:converter] %} {{ann[:converter]}}.to_db {{column.name.id}} {% else %} {{column.name.id}} {% end %}
    {% end %}
    parsed_params
  end

  # Consumes the result set to set self's property values.
  def from_rs(result : DB::ResultSet) : Nil
    {% begin %}
      result.column_names.each do |col|
        case col
        {% for column in @type.instance_vars.select(&.annotation(Granite::Column)) %}
          {% ann = column.annotation(Granite::Column) %}
          when {{column.name.stringify}}
            @{{column.id}} = {% if ann[:converter] %}
              {{ann[:converter]}}.from_rs result
            {% else %}
              value = Granite::Type.from_rs(result, {{ann[:nilable] ? column.type : column.type.union_types.reject { |t| t == Nil }.first}})

              {% if column.has_default_value? && !column.default_value.nil? %}
                return {{column.default_value}} if value.nil?
              {% end %}

              value
            {% end %}
        {% end %}
        else
          # Skip
        end
      end
    {% end %}
    
    # Capture original attributes for dirty tracking if not a new record
    if !new_record?
      ensure_dirty_tracking_initialized
      @original_attributes.not_nil!.clear
      @changed_attributes.not_nil!.clear
      {% for column in @type.instance_vars.select { |ivar| ivar.annotation(Granite::Column) } %}
        {% column_name = column.name.id.stringify %}
        {% ann = column.annotation(Granite::Column) %}
        # Convert value for storage if there's a converter
        {% if ann[:converter] %}
          @original_attributes.not_nil![{{column_name}}] = {{ann[:converter]}}.to_db(@{{column.name.id}}).as(Granite::Base::DirtyValue)
        {% else %}
          # Store the raw value for dirty tracking
          raw_value = @{{column.name.id}}
          @original_attributes.not_nil![{{column_name}}] = raw_value.is_a?(Granite::Base::DirtyValue) ? raw_value : raw_value.to_s.as(Granite::Base::DirtyValue)
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
    {% primary = (options[:primary] && !options[:primary].nil?) ? options[:primary] : false %}
    {% auto = (options[:auto] && !options[:auto].nil?) ? options[:auto] : false %}
    {% auto = (!options || (options && options[:auto] == nil)) && primary %}

    {% nilable = (type.is_a?(Path) ? type.resolve.nilable? : (type.is_a?(Union) ? type.types.any?(&.resolve.nilable?) : (type.is_a?(Generic) ? type.resolve.nilable? : type.nilable?))) %}

    @[Granite::Column(column_type: {{column_type}}, converter: {{converter}}, auto: {{auto}}, primary: {{primary}}, nilable: {{nilable}})]
    @{{decl.var}} : {{decl.type}}? {% unless decl.value.is_a? Nop %} = {{decl.value}} {% end %}

    {% if nilable || primary %}
      def {{decl.var.id}}=(value : {{not_nilable_type}}?)
        # Dirty tracking - only track if we're not a new record
        ensure_dirty_tracking_initialized
        
        if !new_record?
          # Capture original value if not already captured
          if !@original_attributes.not_nil!.has_key?({{decl.var.stringify}})
            {% if converter %}
              @original_attributes.not_nil![{{decl.var.stringify}}] = {{converter}}.to_db(@{{decl.var.id}}).as(Granite::Base::DirtyValue)
            {% else %}
              old_value = @{{decl.var.id}}
              @original_attributes.not_nil![{{decl.var.stringify}}] = old_value.is_a?(Granite::Base::DirtyValue) ? old_value : old_value.to_s.as(Granite::Base::DirtyValue)
            {% end %}
          end
          
          # Convert values for comparison if there's a converter
          {% if converter %}
            old_db_value = {{converter}}.to_db(@{{decl.var.id}}).as(Granite::Base::DirtyValue)
            new_db_value = {{converter}}.to_db(value).as(Granite::Base::DirtyValue)
          {% else %}
            # Handle values that might not be in DirtyValue union
            old_value = @{{decl.var.id}}
            old_db_value = old_value.is_a?(Granite::Base::DirtyValue) ? old_value : old_value.to_s.as(Granite::Base::DirtyValue)
            new_db_value = value.is_a?(Granite::Base::DirtyValue) ? value : value.to_s.as(Granite::Base::DirtyValue)
          {% end %}
          
          if old_db_value != new_db_value
            original = @original_attributes.not_nil![{{decl.var.stringify}}]
            if original == new_db_value
              @changed_attributes.not_nil!.delete({{decl.var.stringify}})
            else
              @changed_attributes.not_nil![{{decl.var.stringify}}] = {original, new_db_value}
            end
          end
        end
        
        @{{decl.var.id}} = value
      end

      def {{decl.var.id}} : {{not_nilable_type}}?
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
        ensure_dirty_tracking_initialized
        @changed_attributes.not_nil!.has_key?({{decl.var.stringify}})
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
        ensure_dirty_tracking_initialized
        if @changed_attributes.not_nil!.has_key?({{decl.var.stringify}})
          @changed_attributes.not_nil![{{decl.var.stringify}}][0].as({{not_nilable_type}}?)
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
        ensure_dirty_tracking_initialized
        if change = @changed_attributes.not_nil![{{decl.var.stringify}}]?
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
        if @previous_changes.not_nil!.has_key?({{decl.var.stringify}})
          @previous_changes.not_nil![{{decl.var.stringify}}][0].as({{not_nilable_type}}?)
        else
          @{{decl.var.id}}
        end
      end
    {% else %}
      def {{decl.var.id}}=(value : {{type.id}})
        # Dirty tracking - only track if we're not a new record
        ensure_dirty_tracking_initialized
        
        if !new_record?
          # Capture original value if not already captured
          if !@original_attributes.not_nil!.has_key?({{decl.var.stringify}})
            {% if converter %}
              @original_attributes.not_nil![{{decl.var.stringify}}] = {{converter}}.to_db(@{{decl.var.id}}).as(Granite::Base::DirtyValue)
            {% else %}
              old_value = @{{decl.var.id}}
              @original_attributes.not_nil![{{decl.var.stringify}}] = old_value.is_a?(Granite::Base::DirtyValue) ? old_value : old_value.to_s.as(Granite::Base::DirtyValue)
            {% end %}
          end
          
          # Convert values for comparison if there's a converter
          {% if converter %}
            old_db_value = {{converter}}.to_db(@{{decl.var.id}}).as(Granite::Base::DirtyValue)
            new_db_value = {{converter}}.to_db(value).as(Granite::Base::DirtyValue)
          {% else %}
            # Handle values that might not be in DirtyValue union
            old_value = @{{decl.var.id}}
            old_db_value = old_value.is_a?(Granite::Base::DirtyValue) ? old_value : old_value.to_s.as(Granite::Base::DirtyValue) 
            new_db_value = value.is_a?(Granite::Base::DirtyValue) ? value : value.to_s.as(Granite::Base::DirtyValue)
          {% end %}
          
          if old_db_value != new_db_value
            original = @original_attributes.not_nil![{{decl.var.stringify}}]
            if original == new_db_value
              @changed_attributes.not_nil!.delete({{decl.var.stringify}})
            else
              @changed_attributes.not_nil![{{decl.var.stringify}}] = {original, new_db_value}
            end
          end
        end
        
        @{{decl.var.id}} = value
      end

      def {{decl.var.id}} : {{type.id}}
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
        ensure_dirty_tracking_initialized
        @changed_attributes.not_nil!.has_key?({{decl.var.stringify}})
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
        ensure_dirty_tracking_initialized
        if @changed_attributes.not_nil!.has_key?({{decl.var.stringify}})
          @changed_attributes.not_nil![{{decl.var.stringify}}][0].as({{type.id}})
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
      def {{decl.var.id}}_change : Tuple({{type.id}}, {{type.id}})?
        ensure_dirty_tracking_initialized
        if change = @changed_attributes.not_nil![{{decl.var.stringify}}]?
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
        if @previous_changes.not_nil!.has_key?({{decl.var.stringify}})
          @previous_changes.not_nil![{{decl.var.stringify}}][0].as({{type.id}})
        else
          @{{decl.var.id}}
        end
      end
    {% end %}
  end

  # include created_at and updated_at that will automatically be updated
  macro timestamps
    column created_at : Time?
    column updated_at : Time?
  end

  def to_h
    fields = {{"Hash(String, Union(#{@type.instance_vars.select(&.annotation(Granite::Column)).map(&.type.id).splat})).new".id}}

    {% for column in @type.instance_vars.select(&.annotation(Granite::Column)) %}
      {% nilable = (column.type.is_a?(Path) ? column.type.resolve.nilable? : (column.type.is_a?(Union) ? column.type.types.any?(&.resolve.nilable?) : (column.type.is_a?(Generic) ? column.type.resolve.nilable? : column.type.nilable?))) %}

      begin
      {% if column.type.id == Time.id %}
        fields["{{column.name}}"] = {{column.name.id}}.try(&.in(Granite.settings.default_timezone).to_s(Granite::DATETIME_FORMAT))
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
    {% for column in @type.instance_vars.select { |ivar| (ann = ivar.annotation(Granite::Column)) && (!ann[:primary] || (ann[:primary] && ann[:auto] == false)) } %}
      if hash.has_key?({{column.stringify}})
        begin
          val = Granite::Type.convert_type hash[{{column.stringify}}], {{column.type}}
        rescue ex : ArgumentError
          error =  Granite::ConversionError.new({{column.name.stringify}}, ex.message)
        end

        if !val.is_a? {{column.type}}
          error = Granite::ConversionError.new({{column.name.stringify}}, "Expected {{column.id}} to be {{column.type}} but got #{typeof(val)}.")
        else
          @{{column}} = val
        end

        errors << error if error
      end
    {% end %}
    self
  end

  def read_attribute(attribute_name : Symbol | String) : Type
    {% begin %}
      case attribute_name.to_s
      {% for column in @type.instance_vars.select(&.annotation(Granite::Column)) %}
        {% ann = column.annotation(Granite::Column) %}
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

  def write_attribute(attribute_name : String | Symbol, value : Granite::Columns::Type)
    {% begin %}
      case attribute_name.to_s
      {% for column in @type.instance_vars.select(&.annotation(Granite::Column)) %}
        when {{column.name.stringify}}
          self.{{column.name.id}} = value.as({{column.type}})
      {% end %}
      else
        raise "Cannot write attribute #{attribute_name}, invalid attribute"
      end
    {% end %}
  end

  def primary_key_value
    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Granite::Column)) && ann[:primary] } %}
      {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
      {{primary_key.id}}
    {% end %}
  end
  
  # Capture current values as original attributes after save
  protected def capture_original_attributes
    ensure_dirty_tracking_initialized
    {% for column in @type.instance_vars.select { |ivar| ivar.annotation(Granite::Column) } %}
      {% column_name = column.name.id.stringify %}
      {% ann = column.annotation(Granite::Column) %}
      # Convert value for storage if there's a converter
      {% if ann[:converter] %}
        @original_attributes.not_nil![{{column_name}}] = {{ann[:converter]}}.to_db(@{{column.name.id}}).as(Granite::Base::DirtyValue)
      {% else %}
        # Store the raw value for dirty tracking
        raw_value = @{{column.name.id}}
        @original_attributes.not_nil![{{column_name}}] = raw_value.is_a?(Granite::Base::DirtyValue) ? raw_value : raw_value.to_s.as(Granite::Base::DirtyValue)
      {% end %}
    {% end %}
  end
end
