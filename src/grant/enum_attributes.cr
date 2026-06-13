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
  #   to `status` and return it;
  # * **scopes** `.draft`, `.published`, `.archived` — class methods returning a
  #   query filtered to that member;
  # * `.statuses` — all enum values (`Array(Status)`);
  # * `.status_mapping` — a `Hash` of underscored member name ⇒ enum value.
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
  # Post.statuses  # => [Post::Status::Draft, Post::Status::Published]
  # ```
  macro enum_attribute(decl, **options)
    {%
      # Parse the declaration
      if decl.is_a?(TypeDeclaration)
        name = decl.var
        type = decl.type
        default = decl.value
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
    {% else %}
      {% enum_type = type.resolve %}
    {% end %}
    
    {% for member in enum_type.constants %}
      # Predicate method (e.g., draft?)
      def {{member.underscore}}? : Bool
        {{name}} == {{enum_type}}::{{member}}
      end
      
      # Bang method to set value (e.g., published!)
      def {{member.underscore}}! : {{enum_type}}
        self.{{name}} = {{enum_type}}::{{member}}
      end
    {% end %}
    
    # Scope for each enum value
    {% for member in enum_type.constants %}
      def self.{{member.underscore}}
        where({{name}}: {{enum_type}}::{{member}})
      end
    {% end %}
    
    # Class methods to access enum values
    def self.{{name.id}}s
      {{enum_type}}.values
    end
    
    # Return mapping of enum names to values
    def self.{{name.id}}_mapping
      {
        {% for member in enum_type.constants %}
          {{member.underscore.stringify}} => {{enum_type}}::{{member}},
        {% end %}
      }
    end
    
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
