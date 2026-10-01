require "./columns"

module Grant
  # Raised when an attribute name does not match any declared column (or
  # `alias_attribute`) of a model.
  #
  # Mirrors ActiveRecord's `ActiveModel::MissingAttributeError` and
  # `ActiveRecord::UnknownAttributeError` for the reflective readers/writers.
  class UnknownAttributeError < ErrorBase
    getter model_name : String
    getter attribute_name : String

    def initialize(@model_name : String, @attribute_name : String)
      super("Unknown attribute '#{@attribute_name}' for #{@model_name}")
    end
  end

  # Raised when a typed dirty-tracking reader (`<attr>_was`, `<attr>_change`)
  # needs the column's converter to turn a stored value back into the column
  # type and the converter defines no `from_db`.
  class ConverterError < ErrorBase
    getter model_name : String
    getter attribute_name : String

    def initialize(@model_name : String, @attribute_name : String, converter : String)
      super("#{converter} must define from_db(value) for typed dirty tracking of #{@model_name}##{@attribute_name}")
    end
  end

  # Compile-time description of one model column, returned by `Model.columns`.
  #
  # `crystal_type` is the column's Crystal type without `Nil` (for example
  # `"Int64"`); `nilable` says whether the column accepts `NULL`; `converter` is
  # the converter type's name when the column declares one.
  struct ColumnInfo
    getter name : String
    getter crystal_type : String
    getter converter : String?

    def initialize(@name : String, @crystal_type : String, @nilable : Bool, @primary : Bool, @converter : String? = nil)
    end

    def nilable? : Bool
      @nilable
    end

    def primary? : Bool
      @primary
    end
  end

  # Attribute introspection for models: `attributes`, `attribute_names`,
  # `has_attribute?`, `[]`/`[]=`, `slice`, `values_at`, `assign_attributes`,
  # `attribute_before_type_cast`, `alias_attribute`, model reflection
  # (`columns`, `columns_hash`, `type_for_attribute`, ...) and a redacting
  # `inspect`.
  #
  # ```
  # user = User.new(name: "Ada", age: "36")
  # user.attributes                        # => {"id" => nil, "name" => "Ada", "age" => 36}
  # user.attribute_before_type_cast("age") # => "36"
  # User.column_names                      # => ["id", "name", "age"]
  # ```
  #
  # Performance: `attributes`, `slice` and `values_at` allocate and run
  # converters on every call. On hot paths use the typed getters (`user.name`)
  # or `to_h`; the reflective readers exist for tooling, forms and logging.
  module Attributes
    # Whether *name* is matched by any entry of *filters*. String entries match
    # as a case-insensitive substring (like ActiveRecord's `filter_attributes`,
    # so `"password"` also filters `password_digest`); Regex entries use their
    # own pattern.
    def self.filtered?(name : String, filters : Array(String | Regex)) : Bool
      filters.any? do |filter|
        if filter.is_a?(Regex)
          filter.matches?(name)
        else
          name.downcase.includes?(filter.downcase)
        end
      end
    end

    @@columns = {} of String => Array(Grant::ColumnInfo)
    @@columns_hashes = {} of String => Hash(String, Grant::ColumnInfo)
    @@lock = Mutex.new

    # :nodoc:
    def self.columns_for(model_name : String, & : -> Array(Grant::ColumnInfo)) : Array(Grant::ColumnInfo)
      @@lock.synchronize { @@columns[model_name] ||= yield }
    end

    # :nodoc:
    def self.columns_hash_for(model_name : String, & : -> Hash(String, Grant::ColumnInfo)) : Hash(String, Grant::ColumnInfo)
      @@lock.synchronize { @@columns_hashes[model_name] ||= yield }
    end

    module ClassMethods
      # All column descriptions, in declaration order. Built on first use and
      # kept for the life of the process, so repeated calls do not allocate; do
      # not mutate the returned array.
      def columns : Array(Grant::ColumnInfo)
        Grant::Attributes.columns_for(name) do
          {% begin %}
            [
              {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
                {% ann = column.annotation(Grant::Column) %}
                Grant::ColumnInfo.new(
                  {{column.name.stringify}},
                  {{ann[:setter_type].stringify}},
                  {{ann[:nilable] ? true : false}},
                  {{ann[:primary] ? true : false}},
                  {% if ann[:converter] %}{{ann[:converter].stringify}}{% else %}nil{% end %}
                ),
              {% end %}
            ] of Grant::ColumnInfo
          {% end %}
        end
      end

      # Column descriptions keyed by column name (built once, like `columns`).
      def columns_hash : Hash(String, Grant::ColumnInfo)
        all_columns = columns
        Grant::Attributes.columns_hash_for(name) do
          by_name = {} of String => Grant::ColumnInfo
          all_columns.each { |column| by_name[column.name] = column }
          by_name
        end
      end

      # The names of all columns (same as `fields`).
      def attribute_names : Array(String)
        fields
      end

      # :ditto:
      def column_names : Array(String)
        fields
      end

      # Whether the model has a column named *name* (aliases resolved).
      def has_column?(name : String | Symbol) : Bool
        {% begin %}
          case resolve_attribute_alias(name.to_s)
          {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
          when {{column.name.stringify}}
            true
          {% end %}
          else
            false
          end
        {% end %}
      end

      # The Crystal type name of column *name* (`"Int64"`, `"String"`...), or
      # nil for an unknown attribute. Aliases resolve to their column.
      def type_for_attribute(name : String | Symbol) : String?
        info = columns_hash[resolve_attribute_alias(name.to_s)]?
        info ? info.crystal_type : nil
      end

      # The Crystal type name of every column, keyed by column name.
      def attribute_types : Hash(String, String)
        types = {} of String => String
        columns.each { |column| types[column.name] = column.crystal_type }
        types
      end

      # The primary key column name (`nil` when the model declares none).
      # Composite keys: see `primary_key_columns`.
      def primary_key : String?
        primary_name
      end

      # Columns that hold application data: excludes the primary key, foreign
      # keys (`*_id`), counters (`*_count`) and the STI type column.
      def content_columns : Array(Grant::ColumnInfo)
        columns.reject do |column|
          column.primary? || column.name.ends_with?("_id") || column.name.ends_with?("_count") || column.name == "type"
        end
      end

      # Whether *name* was declared with `has_secure_token`; such columns are
      # printed as `[FILTERED]` by `inspect`.
      def secure_token_column?(name : String) : Bool
        false
      end

      # Present for ActiveRecord source compatibility. Grant declares columns at
      # compile time, so there is no cached column information to discard.
      def reset_column_information : Nil
      end

      # The column an `alias_attribute` name stands for, or *name* itself.
      def resolve_attribute_alias(name : String) : String
        name
      end

      # Declared `alias_attribute` names mapped to their columns.
      def attribute_aliases : Hash(String, String)
        {} of String => String
      end

      # True once the model declares an `alias_attribute`.
      def has_attribute_aliases? : Bool
        false
      end

      # The names (String) and patterns (Regex) redacted by `inspect`: the
      # global `Grant.settings.filter_attributes` plus any the model adds with
      # `filter_attributes`.
      def filter_attributes : Array(String | Regex)
        Grant.settings.filter_attributes
      end
    end

    macro included
      # Raw values given to mass assignment that differ from the converted
      # value. Created on first capture; never populated when loading rows.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @attributes_before_type_cast : Hash(String, Grant::Columns::Type)?

      # Names assigned through a setter since the record was loaded or last
      # saved (`<attr>_came_from_user?`). Created on first assignment.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @assigned_attributes : Set(String)?
    end

    # Declares *new_name* as another name for the column *old_name*.
    #
    # Generates the getter, setter, `?` and `!` readers, the dirty-tracking
    # helpers and `_before_type_cast`. The alias is also resolved by mass
    # assignment (`new(new_name: ...)`, `assign_attributes`), by `[]`, `[]=`,
    # `has_attribute?`, `slice`, `values_at`, and by `where(new_name: ...)`.
    # It is not resolved by `find_by`, `order` or `pluck`.
    #
    # ```
    # class Post < Grant::Base
    #   column id : Int64, primary: true
    #   column title : String
    #   alias_attribute :name, :title
    # end
    #
    # Post.new(name: "Hello").title # => "Hello"
    # Post.where(name: "Hello")     # WHERE title = 'Hello'
    # ```
    macro alias_attribute(new_name, old_name)
      {% new_str = new_name.id.stringify %}
      {% old_str = old_name.id.stringify %}
      {% if @type.has_constant?(:GRANT_ATTRIBUTE_ALIASES) %}
        {% alias_table = @type.constant(:GRANT_ATTRIBUTE_ALIASES) %}
        {% alias_table[new_str] = old_str %}
      {% else %}
        {% alias_table = {new_str => old_str} %}
        GRANT_ATTRIBUTE_ALIASES = {{alias_table}}
      {% end %}

      def self.resolve_attribute_alias(name : String) : String
        case name
        {% for from, to in alias_table %}
        when {{from}}
          {{to}}
        {% end %}
        else
          name
        end
      end

      def self.attribute_aliases : Hash(String, String)
        {
          {% for from, to in alias_table %}
            {{from}} => {{to}},
          {% end %}
        } of String => String
      end

      def self.has_attribute_aliases? : Bool
        true
      end

      def {{new_name.id}}
        {{old_name.id}}
      end

      def {{new_name.id}}=(value)
        self.{{old_name.id}} = value
      end

      def {{new_name.id}}?
        self.{{old_name.id}}?
      end

      def {{new_name.id}}!
        self.{{old_name.id}}!
      end

      def {{new_name.id}}_changed? : Bool
        {{old_name.id}}_changed?
      end

      def {{new_name.id}}_was
        {{old_name.id}}_was
      end

      def {{new_name.id}}_change
        {{old_name.id}}_change
      end

      def {{new_name.id}}_will_change! : Nil
        {{old_name.id}}_will_change!
      end

      def {{new_name.id}}_in_database
        {{old_name.id}}_in_database
      end

      def {{new_name.id}}_before_type_cast : Grant::Columns::Type
        {{old_name.id}}_before_type_cast
      end
    end

    # Adds names or patterns to the values `inspect` redacts for this model, on
    # top of `Grant.settings.filter_attributes`. Symbols and strings match as
    # case-insensitive substrings of the column name.
    #
    # ```
    # class User < Grant::Base
    #   filter_attributes :token, /secret/i
    # end
    # ```
    macro filter_attributes(*names)
      # Bound values of these columns are also redacted from the SQL log.
      Grant::Encryption::LogFilter.track(self)

      def self.filter_attributes : Array(String | Regex)
        filters = Grant.settings.filter_attributes.dup
        {% for name in names %}
          {% if name.is_a?(RegexLiteral) %}
            filters << ({{name}}).as(String | Regex)
          {% else %}
            filters << {{name.id.stringify}}.as(String | Regex)
          {% end %}
        {% end %}
        filters
      end
    end

    # Every attribute as a name => value hash. Values are converter-applied
    # database values, as `read_attribute` returns. Allocates a hash per call;
    # use `to_h` or the typed getters on hot paths.
    #
    # ```
    # user.attributes # => {"id" => 1, "name" => "Ada"}
    # ```
    def attributes : Hash(String, Grant::Columns::Type)
      result = {} of String => Grant::Columns::Type
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        {% ann = column.annotation(Grant::Column) %}
        {% if ann[:converter] %}
          result[{{column.name.stringify}}] = {{ann[:converter]}}.to_db(@{{column.name.id}})
        {% else %}
          result[{{column.name.stringify}}] = @{{column.name.id}}
        {% end %}
      {% end %}
      result
    end

    # Mass-assigns *hash* by attribute name, converting values like `new`.
    # Conversion failures are recorded in `errors`. Returns self.
    #
    # ```
    # user.assign_attributes({"name" => "Ada", "age" => "36"})
    # ```
    #
    # A key that names no attribute (column, alias, association, virtual or
    # encrypted attribute, value object) raises `Grant::UnknownAttributeError`
    # before anything is assigned. `new`, `create` and `update` keep ignoring
    # unknown keys.
    def assign_attributes(hash : Hash) : self
      hash.each_key do |key|
        attribute_name = key.to_s
        raise Grant::UnknownAttributeError.new(self.class.name, attribute_name) unless assignable_attribute?(attribute_name)
      end
      set_attributes(hash.transform_keys { |key| key.to_s.as(String | Symbol) })
    end

    # :ditto:
    def assign_attributes(**args) : self
      assign_attributes(args.to_h)
    end

    # Writer form of `assign_attributes(hash)`.
    def attributes=(hash : Hash)
      assign_attributes(hash)
      hash
    end

    # Whether mass assignment knows *name*: a column or alias, an association,
    # a virtual or encrypted attribute, or a value object.
    def assignable_attribute?(name : String | Symbol) : Bool
      attribute = self.class.resolve_attribute_alias(name.to_s)
      return true if self.class.has_column?(attribute)
      return true if Grant::Columns::VirtualAttributeRegistry.registered?(self.class.name, attribute)
      return true if Grant::AssociationRegistry.reflection(self.class.name, attribute)
      return true if self.class.encrypted_attributes.has_key?(attribute)
      {% if @type.class.has_method?(:aggregations) %}
        return true if self.class.aggregations.has_key?(attribute.to_sym)
      {% end %}
      false
    end

    # True when *name* was assigned through its setter (or by mass assignment)
    # since the record was loaded, saved or had its changes cleared, like
    # ActiveModel's `<attr>_came_from_user?`. Assigning the value it already
    # holds counts.
    def attribute_came_from_user?(name : String | Symbol) : Bool
      assigned = @assigned_attributes
      return false unless assigned
      assigned.includes?(self.class.resolve_attribute_alias(name.to_s))
    end

    # The column names of this record's model.
    def attribute_names : Array(String)
      self.class.attribute_names
    end

    # Whether *name* is a column (or alias) of this record's model.
    def has_attribute?(name : String | Symbol) : Bool
      self.class.has_column?(name)
    end

    # Whether the attribute holds a value: not nil and not an empty String,
    # Array or Slice. An unknown attribute raises `Grant::UnknownAttributeError`.
    def attribute_present?(name : String | Symbol) : Bool
      value = self[name]
      if value.nil?
        false
      elsif value.is_a?(String) || value.is_a?(Array) || value.is_a?(Slice)
        !value.empty?
      else
        true
      end
    end

    # Reads the attribute *name* (aliases resolved) as `read_attribute` does.
    # Raises `Grant::UnknownAttributeError` for an unknown name.
    def [](name : String | Symbol) : Grant::Columns::Type
      read_column_value(resolved_attribute_name(name))
    end

    # Writes the attribute *name* (aliases resolved) through its typed setter.
    def []=(name : String | Symbol, value : Grant::Columns::Type)
      write_attribute(resolved_attribute_name(name), value)
      value
    end

    # A hash of just the named attributes, keyed as given.
    #
    # ```
    # user.slice(:id, :name) # => {"id" => 1, "name" => "Ada"}
    # ```
    def slice(*names : String | Symbol) : Hash(String, Grant::Columns::Type)
      result = {} of String => Grant::Columns::Type
      names.each { |name| result[name.to_s] = self[name] }
      result
    end

    # The values of the named attributes, in the order given.
    def values_at(*names : String | Symbol) : Array(Grant::Columns::Type)
      values = [] of Grant::Columns::Type
      names.each { |name| values << self[name] }
      values
    end

    # The value assigned to *name* before Grant converted it. Only mass
    # assignment (`new`, `assign_attributes`, `update`) keeps the raw input, and
    # only when conversion changed it; otherwise, and for records loaded from the
    # database, this is the attribute's current value.
    #
    # ```
    # user = User.new(age: "36")
    # user.age                               # => 36
    # user.attribute_before_type_cast("age") # => "36"
    # ```
    def attribute_before_type_cast(name : String | Symbol) : Grant::Columns::Type
      attribute = resolved_attribute_name(name)
      store = @attributes_before_type_cast
      if store && store.has_key?(attribute)
        store[attribute]
      else
        read_column_value(attribute)
      end
    end

    # Keeps *raw* as the before-type-cast value of *attribute*.
    protected def capture_before_type_cast(attribute : String, raw : Grant::Columns::Type) : Nil
      store = @attributes_before_type_cast
      unless store
        store = {} of String => Grant::Columns::Type
        @attributes_before_type_cast = store
      end
      store[attribute] = raw
    end

    # Forgets the raw input of *attribute*; a typed write supersedes it.
    protected def discard_before_type_cast(attribute : String) : Nil
      store = @attributes_before_type_cast
      store.delete(attribute) if store
      (@assigned_attributes ||= Set(String).new) << attribute
    end

    # Forgets every retained raw input, for example after `reload`.
    protected def clear_before_type_cast : Nil
      @attributes_before_type_cast = nil
      @assigned_attributes = nil
    end

    # Forgets which attributes were assigned (a save or cleared changes make
    # the current values the database's).
    protected def clear_assigned_attributes : Nil
      @assigned_attributes = nil
    end

    private def resolved_attribute_name(name : String | Symbol) : String
      attribute = self.class.resolve_attribute_alias(name.to_s)
      raise Grant::UnknownAttributeError.new(self.class.name, attribute) unless self.class.has_column?(attribute)
      attribute
    end

    private def read_column_value(attribute : String) : Grant::Columns::Type
      {% begin %}
        case attribute
        {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
          {% ann = column.annotation(Grant::Column) %}
        when {{column.name.stringify}}
          {% if ann[:converter] %}
            {{ann[:converter]}}.to_db(@{{column.name.id}})
          {% else %}
            @{{column.name.id}}
          {% end %}
        {% end %}
        else
          raise Grant::UnknownAttributeError.new(self.class.name, attribute)
        end
      {% end %}
    end

    # A readable, redacted representation: only column values, none of the
    # dirty-tracking state. Values of columns matched by `filter_attributes`,
    # encrypted columns and `has_secure_token` columns print as `[FILTERED]`
    # (nil stays `nil`).
    #
    # ```
    # user.inspect # => #<User id: 1, email: "a@b.c", password_digest: [FILTERED]>
    # ```
    def inspect(io : IO) : Nil
      filters = self.class.filter_attributes
      io << "#<" << self.class.name
      separator = " "
      {% for column in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        io << separator << {{column.name.stringify}} << ": "
        separator = ", "
        inspect_attribute_value(io, {{column.name.stringify}}, @{{column.name.id}}, filters)
      {% end %}
      io << '>'
    end

    private def inspect_attribute_value(io : IO, name : String, value, filters : Array(String | Regex)) : Nil
      if value.nil?
        io << "nil"
      elsif Grant::Attributes.filtered?(name, filters) || encrypted_column?(name) || self.class.secure_token_column?(name)
        io << "[FILTERED]"
      elsif value.is_a?(String) && value.size > 50
        io << value[0, 50].inspect.rchop << "...\""
      else
        value.inspect(io)
      end
    end

    private def encrypted_column?(name : String) : Bool
      attributes = self.class.encrypted_attributes
      return true if attributes[name]?.try(&.transparent?)
      name.ends_with?("_encrypted") && attributes.has_key?(name.rchop("_encrypted"))
    end
  end
end
