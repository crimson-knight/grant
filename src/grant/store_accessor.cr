# Typed accessors for individual keys of a `serialized_column`, in the style of
# Rails' `store_accessor`.
#
# The column's value class holds the keys as typed properties (it is
# `JSON::Serializable`, so nothing is untyped); `store_accessor` generates a typed
# getter and setter per key plus `_changed?` / `_was` dirty helpers. Reads reuse
# the object `serialized_column` already caches, so reading a key never
# deserializes the column again. A write assigns the property on that same object
# and re-serializes the column once (through the column's own setter, so the
# record's dirty tracking and `before_save` serialization keep working).
#
# ```
# class UserSettings
#   include JSON::Serializable
#   property theme : String = "light"
#   property notifications : Bool = true
# end
#
# class User < Grant::Base
#   column id : Int64, primary: true
#   serialized_column :settings, UserSettings
#   store_accessor :settings, theme : String = "light", notifications : Bool = true
# end
#
# u = User.new
# u.theme          # => "light"  (default; nothing built yet)
# u.theme = "dark" # builds UserSettings, marks the column dirty
# u.theme_changed? # => true
# u.theme_was      # => "light"
# u.notifications? # => true
# ```
#
# Keys typed `Bool` also get a `key?` predicate. `prefix: true` (or a Symbol or
# String) and `suffix:` name the accessors `settings_theme` and so on, to avoid
# collisions between stores.
module Grant::StoreAccessor
  # Declares typed accessors for *keys* of the serialized column *store*.
  #
  # Each key is a type declaration with its default (used while the column holds
  # no object yet), for example `theme : String = "light"`. A nilable key may omit
  # the default. The store's value class must have a settable property of the
  # same name and a zero-argument constructor.
  macro store_accessor(store, *keys, **options)
    {% prefix = options[:prefix] %}
    {% suffix = options[:suffix] %}
    {% name_prefix = (prefix == nil || prefix == false) ? "" : (prefix == true ? "#{store.id}_" : "#{prefix.id}_") %}
    {% name_suffix = (suffix == nil || suffix == false) ? "" : (suffix == true ? "_#{store.id}" : "_#{suffix.id}") %}

    {% for key in keys %}
      {% unless key.is_a?(TypeDeclaration) %}
        {% raise "store_accessor keys must be type declarations like `theme : String = \"light\"`" %}
      {% end %}
      {% key_name = key.var.id %}
      {% accessor = "#{name_prefix.id}#{key_name}#{name_suffix.id}".id %}
      {% key_type = key.type %}
      {% if key.value.is_a?(Nop) %}
        {% default = "nil".id %}
      {% else %}
        {% default = key.value %}
      {% end %}
      {% ivar = "_store_#{store.id}_#{accessor}".id %}

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ ivar }}_was : {{ key_type }}? = nil

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ ivar }}_dirty : Bool = false

      # Reads *{{ key_name }}* from the cached {{ store.id }} object, or its default.
      def {{ accessor }} : {{ key_type }}
        if object = self.{{ store.id }}
          object.{{ key_name }}
        else
          {{ default }}
        end
      end

      {% if key_type.resolve <= Bool %}
        def {{ accessor }}? : Bool
          {{ accessor }} == true
        end
      {% end %}

      # Assigns *{{ key_name }}* on the {{ store.id }} object (building it when
      # absent) and re-serializes the column once.
      def {{ accessor }}=(value : {{ key_type }}) : {{ key_type }}
        current = {{ accessor }}
        unless @{{ ivar }}_dirty
          @{{ ivar }}_was = current
          @{{ ivar }}_dirty = true
        end
        {% klass = "typeof(self.#{store.id}.not_nil!)".id %}
        object = self.{{ store.id }} || {{ klass }}.new
        object.{{ key_name }} = value
        self.{{ store.id }} = object
        @{{ ivar }}_dirty = false if value == @{{ ivar }}_was
        value
      end

      # True when *{{ key_name }}* was assigned since the last save.
      def {{ accessor }}_changed? : Bool
        @{{ ivar }}_dirty
      end

      # The value of *{{ key_name }}* before it was changed (the current value when
      # unchanged).
      def {{ accessor }}_was : {{ key_type }}
        if @{{ ivar }}_dirty
          was = @{{ ivar }}_was
          was.nil? ? {{ default }} : was
        else
          {{ accessor }}
        end
      end

      after_save :_reset_{{ ivar }}_tracking

      private def _reset_{{ ivar }}_tracking
        @{{ ivar }}_dirty = false
        @{{ ivar }}_was = nil
      end
    {% end %}
  end
end

abstract class Grant::Base
  include Grant::StoreAccessor
end
