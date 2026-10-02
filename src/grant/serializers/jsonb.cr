require "json"
require "./json"

module Grant::Serializers
  # JSONB uses the same serialization as JSON. The storage difference (a
  # native jsonb column on PostgreSQL, JSON text elsewhere) is decided by the
  # column type, not by the serializer.
  class JSONB < JSON
  end
end

module Grant::Converters
  # Stores a `JSON::Any` document. PostgreSQL keeps it in a native `jsonb`
  # column; SQLite and MySQL keep the JSON text. Columns typed `JSON::Any`
  # use it without declaring a converter.
  module JsonDocument
    extend self

    def to_db(value : ::JSON::Any?) : Grant::Columns::Type
      return if value.nil?
      value.to_json
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : ::JSON::Any?
      case value
      when String then ::JSON.parse(value)
      when Slice  then ::JSON.parse(String.new(value))
      end
    end

    def from_rs(result : ::DB::ResultSet) : ::JSON::Any?
      value = result.read
      case value
      when Nil                then nil
      when String             then ::JSON.parse(value)
      when ::JSON::Any        then value
      when ::JSON::PullParser then ::JSON::Any.new(value)
      when Bytes              then ::JSON.parse(String.new(value))
      else
        raise ArgumentError.new("Cannot read #{value.class} as a JSON document")
      end
    end
  end
end

# Typed accessors for individual keys of a `JSON::Any` document column; the
# JSON counterpart of `store_accessor` on a `serialized_column`, which
# `store_accessor` hands over to when its store is a JSON::Any column.
#
# ```
# class User < Grant::Base
#   column id : Int64, primary: true
#   column settings : JSON::Any?, type: :jsonb
#   store_accessor :settings, theme : String = "light", beta : Bool = false, ratio : Float64?
# end
#
# user = User.new
# user.theme = "dark" # builds the document, keeps its other keys
# user.theme_changed? # => true
# user.theme_was      # => "light"
# ```
#
# Supported key types are `String`, `Int32`, `Int64`, `Float64`, `Bool` and
# `JSON::Any`, each optionally nilable. A key that is missing, `null` or of
# another JSON type reads as its default. Assigning `nil` writes a JSON `null`.
# A write replaces the document with an edited copy through the column's own
# setter, so dirty tracking and `save` work as for any column.
module Grant::JsonStoreAccessor
  # `Model#column` of every JSON::Any column, recorded by the `column` macro so
  # `store_accessor` can tell a JSON document from a serialized object (a
  # class body cannot read its instance variables yet).
  JSON_COLUMNS = {} of String => Bool

  macro json_store_accessor(store, *keys, **options)
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
      {% base_type = key_type.is_a?(Union) ? key_type.types.reject { |member| member.resolve == Nil }.first.resolve : key_type.resolve %}
      {% nilable_key = key_type.is_a?(Union) || key_type.resolve == Nil %}
      {% default = key.value.is_a?(Nop) ? "nil".id : key.value %}
      {% if base_type == String %}
        {% reader = "as_s?".id %}
      {% elsif base_type == Int32 %}
        {% reader = "as_i?".id %}
      {% elsif base_type == Int64 %}
        {% reader = "as_i64?".id %}
      {% elsif base_type == Float64 %}
        {% reader = "as_f?".id %}
      {% elsif base_type == Bool %}
        {% reader = "as_bool?".id %}
      {% elsif base_type == JSON::Any %}
        {% reader = nil %}
      {% else %}
        {% raise "store_accessor on a JSON column supports String, Int32, Int64, Float64, Bool and JSON::Any keys, not #{base_type}" %}
      {% end %}
      {% ivar = "_json_store_#{store.id}_#{accessor}".id %}

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ ivar }}_was : {{ base_type }}? = nil

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ ivar }}_dirty : Bool = false

      # Reads *{{ key_name }}* from the {{ store.id }} document, or its default.
      def {{ accessor }} : {{ key_type }}
        if document = self.{{ store.id }}
          if member = document[{{ key_name.stringify }}]?
            {% if reader %}
              unless (typed = member.{{ reader }}).nil?
                return typed
              end
            {% else %}
              return member unless member.raw.nil?
            {% end %}
          end
        end
        {{ default }}
      end

      {% if base_type == Bool %}
        def {{ accessor }}? : Bool
          {{ accessor }} == true
        end
      {% end %}

      # Assigns *{{ key_name }}* in a copy of the {{ store.id }} document
      # (building it when absent) and assigns the copy to the column.
      def {{ accessor }}=(value : {{ key_type }}) : {{ key_type }}
        current = {{ accessor }}
        unless @{{ ivar }}_dirty
          @{{ ivar }}_was = current
          @{{ ivar }}_dirty = true
        end
        members = if (document = self.{{ store.id }}) && (existing = document.as_h?)
                    existing.dup
                  else
                    {} of String => JSON::Any
                  end
        {% if base_type == JSON::Any %}
          members[{{ key_name.stringify }}] = value || JSON::Any.new(nil)
        {% elsif base_type == Int32 %}
          members[{{ key_name.stringify }}] = JSON::Any.new(value.try(&.to_i64))
        {% else %}
          members[{{ key_name.stringify }}] = JSON::Any.new(value)
        {% end %}
        self.{{ store.id }} = JSON::Any.new(members)
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
