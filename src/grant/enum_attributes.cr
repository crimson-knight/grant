# Rails-style enum attributes for Grant models, backed by native Crystal enums.
#
# `enum_attribute status : Status` stores the enum in a column (as a `String` by
# default, via `Grant::Converters::Enum`) and generates a family of helper methods
# — predicates, bang-setters, and class-level scopes — for ergonomic, type-safe
# access. This module is mixed into every `Grant::Base`, so the macro is available
# on any model.
#
# ```
# class Post < Grant::Base
#   column id : Int64, primary: true
#   column title : String
#
#   enum Status
#     Draft
#     Published
#     Archived
#   end
#
#   enum_attribute status : Status = :draft # default value
# end
#
# post = Post.new
# post.draft?     # => true  (matches the :draft default)
# post.published? # => false
# post.published! # sets status to Post::Status::Published
# post.status     # => Post::Status::Published
#
# Post.published.select # => Array(Post) where status == Published (a scope)
# ```
module Grant::EnumAttributes
  # Defines an enum-backed column and its helper methods from a type declaration
  # like `status : Status` (with an optional default, e.g. `status : Status = :draft`).
  #
  # The column is persisted as a `String` by default (override with
  # `column_type: Int32` to store the enum's integer value, or pass an explicit
  # `converter:`). Nilable types (`status : Status?`) are supported.
  #
  # For an enum with members `Draft`, `Published`, `Archived`, and an attribute
  # named `status`, this generates:
  #
  # * the column `status` with a `Grant::Converters::Enum` converter;
  # * **predicates** `#draft? : Bool`, `#published? : Bool`, `#archived? : Bool`
  #   — true when `status` equals that member;
  # * **bang-setters** `#draft!`, `#published!`, `#archived!` — assign that member
  #   and `save!` it, like Rails' `update!` (one INSERT or UPDATE; validations
  #   and callbacks run; raises `Grant::RecordInvalid` on failure);
  # * **in-memory setters** `#assign_draft`, `#assign_published`, ... — assign
  #   without saving;
  # * **scopes** `.draft`, `.published`, `.archived` and negated
  #   `.not_draft`, ... — class methods returning a query filtered to that member;
  # * `#status=(String | Symbol)` — assigns by member name;
  # * `.statuses` — Rails' mapping: a `Hash` of underscored member name ⇒ enum
  #   value (`Status.values` lists the members);
  # * `.status_mapping` — the same hash, kept for older callers;
  # * `#status_previously_was` — the member before the last save.
  #
  # Mass assignment (`new`, `assign_attributes`) accepts a member, a name or a
  # symbol; an unknown name raises (or fails validation with `validate:`) the
  # same way `status = "bogus"` does. `normalizes` may be declared on the same
  # column.
  #
  # Options: `prefix:` / `suffix:` (true, a Symbol or a String) rename the
  # generated methods, `scopes: false` skips the scopes, and `validate: true`
  # (or `validate: {allow_nil: true}`) reports unknown names and nil through
  # validation instead of raising `Grant::UnknownEnumValueError`.
  #
  # A default given as a symbol (`= :draft`) or an enum literal is applied via an
  # `after_initialize` hook to new records only.
  #
  # ```
  # class Post < Grant::Base
  #   column id : Int64, primary: true
  #   enum Status
  #     Draft
  #     Published
  #   end
  #   enum_attribute status : Status = :draft
  # end
  #
  # p = Post.new
  # p.draft?       # => true
  # p.published!   # => Post::Status::Published
  # p.published?   # => true
  # Post.published # => query scoped to status == Published
  # Post.statuses  # => {"draft" => Post::Status::Draft, "published" => Post::Status::Published}
  # ```
  macro enum_attribute(decl, **options)
    {%
      # Parse the declaration
      if decl.is_a?(TypeDeclaration)
        name = decl.var
        type = decl.type
        default = decl.value || options[:default]
      else
        raise "enum_attribute expects a type declaration like 'status : Status'"
      end
    %}

    {% column_type = options[:column_type] || String %}
    {% converter = options[:converter] %}

    # Define the column with enum converter
    {% if converter %}
      column {{name}} : {{type}}, converter: {{converter}}
    {% else %}
      {% if type.resolve.nilable? %}
        {% enum_converter_type = type.resolve.union_types.find { |t| t != Nil } %}
      {% else %}
        {% enum_converter_type = type %}
      {% end %}
      column {{name}} : {{type}}, converter: Grant::Converters::Enum({{enum_converter_type}}, {{column_type}})
    {% end %}

    # Generate helper methods for each enum value
    {% if type.resolve.nilable? %}
      {% enum_type = type.resolve.union_types.find { |t| t != Nil } %}
      {% type_nilable = true %}
    {% else %}
      {% enum_type = type.resolve %}
      {% type_nilable = false %}
    {% end %}

    # `prefix:` / `suffix:` (true, a Symbol or a String) disambiguate members
    # shared between two enums: `prefix: true` gives `status_draft?`,
    # `suffix: :state` gives `draft_state?`.
    {% prefix = options[:prefix] %}
    {% suffix = options[:suffix] %}
    {% name_prefix = (prefix == nil || prefix == false) ? "" : (prefix == true ? "#{name.id}_" : "#{prefix.id}_") %}
    {% name_suffix = (suffix == nil || suffix == false) ? "" : (suffix == true ? "_#{name.id}" : "_#{suffix.id}") %}
    {% define_scopes = options[:scopes] != false %}

    {% for member in enum_type.constants %}
      {% method_name = "#{name_prefix.id}#{member.underscore}#{name_suffix.id}" %}

      # Predicate method (e.g., draft?)
      def {{method_name.id}}? : Bool
        {{name}} == {{enum_type}}::{{member}}
      end

      # Sets the value in memory only (e.g., assign_published).
      def assign_{{method_name.id}} : {{enum_type}}
        self.{{name}} = {{enum_type}}::{{member}}
      end

      # Sets the value and saves it like Rails' `update!` (validations and
      # callbacks run, one INSERT or UPDATE round trip; raises on failure).
      # Use `assign_<member>` to set it in memory only. Returns the enum member.
      def {{method_name.id}}! : {{enum_type}}
        self.{{name}} = {{enum_type}}::{{member}}
        save!
        {{enum_type}}::{{member}}
      end

      {% if define_scopes %}
        # Scope for the enum value (e.g., Post.published)
        def self.{{method_name.id}}
          where({{name}}: {{enum_type}}::{{member}})
        end

        # Negated scope (e.g., Post.not_published)
        def self.not_{{method_name.id}}
          where.not({{name}}: {{enum_type}}::{{member}})
        end
      {% end %}
    {% end %}

    # Class methods to access enum values
    {% plural_name = name.id.stringify %}
    {% if plural_name.ends_with?("s") %}
      {% plural_name = plural_name + "es" %}
    {% else %}
      {% plural_name = plural_name + "s" %}
    {% end %}
    def self.{{plural_name.id}} : Hash(String, {{enum_type}})
      {{name.id}}_mapping
    end

    # Return mapping of enum names to values
    def self.{{name.id}}_mapping : Hash(String, {{enum_type}})
      {
        {% for member in enum_type.constants %}
          {{member.underscore.stringify}} => {{enum_type}}::{{member}},
        {% end %}
      } of String => {{enum_type}}
    end

    # Looks a member up by its underscored name (String or Symbol), or by
    # its enum name; nil when unknown.
    # :nodoc:
    def self.__enum_lookup_{{name.id}}(value : String | Symbol) : {{enum_type}}?
      text = value.to_s
      {{enum_type}}.values.find { |member| member.to_s.underscore == text.underscore }
    end

    # Query values: a member, its name (`where(status: "published")`) or its
    # symbol are all converted to the stored representation.
    # :nodoc:
    def self.__coerce_where_{{name.id}}(value)
      {% if converter %}
        {% enum_converter = converter %}
      {% else %}
        {% enum_converter = "Grant::Converters::Enum(#{enum_type}, #{column_type})".id %}
      {% end %}
      if value.is_a?({{enum_type}})
        {{enum_converter}}.to_db(value)
      elsif value.is_a?(String) || value.is_a?(Symbol)
        if member = __enum_lookup_{{name.id}}(value)
          {{enum_converter}}.to_db(member)
        else
          value
        end
      {% if !converter %}
      elsif value.is_a?(Array)
        converted = [] of {% if column_type.resolve <= Number %}Int64{% else %}String{% end %}
        value.each do |item|
          member = item.is_a?({{enum_type}}) ? item : ((item.is_a?(String) || item.is_a?(Symbol)) ? __enum_lookup_{{name.id}}(item) : nil)
          return value unless member
          converted << {{enum_converter}}.to_db(member).as({% if column_type.resolve <= Number %}Int64{% else %}String{% end %})
        end
        converted
      {% end %}
      else
        value
      end
    end

    # Assigns by name. An unknown name raises `Grant::UnknownEnumValueError`,
    # or, with `validate:`, is remembered and reported by validation.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_invalid_enum_{{name.id}} : String? = nil

    # Any assignment through the column setter (a member or nil) replaces a
    # previously remembered unknown name, so validation reflects the latest
    # value. (A separate hook from `__assign_hook_*`, which `normalizes` owns.)
    private def __after_assign_{{name.id}}(value)
      @_invalid_enum_{{name.id}} = nil
    end

    # Mass assignment of a name or symbol goes through `status=(String | Symbol)`
    # so an unknown name follows `validate:` instead of becoming a conversion
    # error.
    private def __mass_assign_special_{{name.id}}(value) : Bool
      if value.is_a?(String) || value.is_a?(Symbol)
        self.{{name.id}} = value
        true
      else
        false
      end
    end

    def {{name.id}}=(value : String | Symbol)
      if member = self.class.__enum_lookup_{{name.id}}(value)
        @_invalid_enum_{{name.id}} = nil
        self.{{name.id}} = member
      else
        {% if options[:validate] %}
          @_invalid_enum_{{name.id}} = value.to_s
        {% else %}
          raise Grant::UnknownEnumValueError.new("'#{value}' is not a valid {{name.id}}")
        {% end %}
      end
    end

    {% if options[:validate] %}
      {% allow_nil = type_nilable && options[:validate].is_a?(NamedTupleLiteral) && options[:validate][:allow_nil] %}
      validate "{{name.id}} is not included in the list" do |model|
        model.@_invalid_enum_{{name.id}}.nil? && {% if allow_nil %}true{% else %}!model.{{name.id}}.nil?{% end %}
      end
    {% end %}

    # Add default value if specified
    {% if default %}
      after_initialize do
        if @{{name}}.nil? && new_record?
          @{{name}} = {% if default.is_a?(SymbolLiteral) %}
            {{enum_type}}::{{default.id.camelcase}}
          {% else %}
            {{default}}
          {% end %}
        end
      end
    {% end %}
  end

  # Defines several enum attributes in one call.
  #
  # Each keyword maps an attribute name to either an enum type (shorthand) or a
  # `HashLiteral` of `{type: ..., column_type: ...}` for extra options. Equivalent
  # to calling `enum_attribute` once per entry.
  #
  # ```
  # class Order < Grant::Base
  #   column id : Int64, primary: true
  #   enum Status
  #     Pending; Shipped
  #   end
  #   enum Priority
  #     Low; High
  #   end
  #
  #   enum_attributes status: Status, priority: {type: Priority, column_type: Int32}
  # end
  #
  # Order.new.pending? # => true once defaulted; predicates/scopes exist for both
  # ```
  macro enum_attributes(**mappings)
    {% for name, config in mappings %}
      {% if config.is_a?(HashLiteral) %}
        enum_attribute {{name}} : {{config[:type]}}, {{**config}}
      {% else %}
        enum_attribute {{name}} : {{config}}
      {% end %}
    {% end %}
  end

  # Validation helpers for enum attributes, extended onto every `Grant::Base`.
  module Validations
    # Validates that *field* holds a value valid for its enum.
    #
    # Adds a model validation that fails if the field's stored value is not a
    # member of the enum. Pass `allow_nil: true` to permit a `nil` value, and
    # `message:` to customize the error text.
    #
    # ```
    # class Post < Grant::Base
    #   column id : Int64, primary: true
    #   enum Status
    #     Draft; Published
    #   end
    #   enum_attribute status : Status = :draft
    #   validates_enum :status
    # end
    #
    # Post.new.valid? # => true (status defaults to a real member)
    # ```
    macro validates_enum(field, **options)
      {% message = options[:message] || "is not a valid value" %}
      {% allow_nil = options[:allow_nil] || false %}
      
      validate "{{field}} {{message}}" do |model|
        value = model.{{field}}
        {% if allow_nil %}
          value.nil? || {{field.id.camelcase}}.valid?(value)
        {% else %}
          !value.nil? && {{field.id.camelcase}}.valid?(value)
        {% end %}
      end
    end
  end
end

# Include in Grant::Base
abstract class Grant::Base
  include Grant::EnumAttributes
  extend Grant::EnumAttributes::Validations
end

# Raised when an enum attribute is assigned a name that is not a member of its
# enum (for example `post.status = "bogus"`) and the attribute was declared
# without `validate:`.
class Grant::UnknownEnumValueError < Grant::ErrorBase
end
