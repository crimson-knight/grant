# Canonicalizes attribute values on assignment, in the style of Rails'
# `normalizes`.
#
# `normalizes :email, with: ->(value : String) { value.strip.downcase }`
# rewrites the attribute every time it is assigned through its setter (so
# `new`, `create`, `update`, `attributes=` and `email = ...` all normalize), and
# rewrites the value of equality conditions on that column, so
# `User.find_by(email: " A@B.COM ")` matches the stored `a@b.com`.
# Values read from the database are **not** normalized: hydration assigns the
# instance variables directly, so loading rows pays nothing.
#
# The macro is available on every `Grant::Base`; no `include` is required
# (`include Grant::Normalization` is still accepted for older models).
#
# ```
# class User < Grant::Base
#   column id : Int64, primary: true
#   column email : String?
#   column handle : String?
#   column age : Int32?
#
#   normalizes :email, :handle, with: ->(value : String) { value.strip.downcase }
#   normalizes :age, with: ->(value : Int32) { value.clamp(0, 150) }
#   normalizes :handle, apply_to_nil: true do |value|
#     value || "anonymous"
#   end
# end
#
# u = User.new(email: "  Alice@Example.COM ")
# u.email                                    # => "alice@example.com"
# User.normalize_value_for(:email, " A@X ")  # => "a@x"
# User.find_by(email: " ALICE@EXAMPLE.COM ") # matches the stored row
# ```
#
# Performance: each normalized column contributes one generated class method
# (`__normalize_<column>`); models without `normalizes` generate nothing and
# query building for them only calls an inlined pass-through.
module Grant::Normalization
  # Retained so `include Grant::Normalization` keeps compiling; normalization no
  # longer needs a hook.
  macro included
  end

  # Class-level helpers, extended onto every `Grant::Base`.
  module ClassMethods
    # Applies the normalizer declared for *attribute* to *value*; returns *value*
    # unchanged when the attribute has no normalizer or the value has a different
    # type. Mirrors `Model.normalize_value_for` in Rails.
    #
    # ```
    # User.normalize_value_for(:email, " A@X ") # => "a@x"
    # ```
    def normalize_value_for(attribute : Symbol | String, value)
      name = attribute.to_s
      {% for method in @type.class.methods %}
        {% if method.name.starts_with?("__normalize_") %}
          {% column = method.name.gsub(/^__normalize_/, "") %}
          {% ivar = @type.instance_vars.find { |v| v.name.stringify == column } %}
          {% if ivar %}
            if name == {{ column.stringify }} && value.is_a?({{ ivar.annotation(Grant::Column)[:setter_type] }})
              return {{ method.name.id }}(value)
            end
          {% end %}
        {% end %}
      {% end %}
      value
    end

    # Coerces a value used in an equality condition on *field* (a `where` or
    # `find_by` argument) through the column's enum lookup and normalizer.
    # Columns with neither pass the value straight through.
    #
    # :nodoc:
    def coerce_where_value(field : String, value)
      {% for method in @type.class.methods %}
        {% if method.name.starts_with?("__normalize_") %}
          {% column = method.name.gsub(/^__normalize_/, "") %}
          {% ivar = @type.instance_vars.find { |v| v.name.stringify == column } %}
          {% if ivar %}
            if field == {{ column.stringify }}
              if value.is_a?({{ ivar.annotation(Grant::Column)[:setter_type] }})
                return {{ method.name.id }}(value)
              {% element_type = ivar.type.union_types.reject { |type| type == Nil }.first %}
              elsif value.is_a?(Array({{ element_type }}))
                # `where(email: [...])` (IN): normalize each element, keeping the
                # array's element type so it still binds as a column value.
                return value.map do |element|
                  normalized = {{ method.name.id }}(element)
                  normalized.is_a?({{ element_type }}) ? normalized : element
                end
              end
            end
          {% end %}
        {% end %}
        {% if method.name.starts_with?("__coerce_where_") %}
          {% column = method.name.gsub(/^__coerce_where_/, "") %}
          return {{ method.name.id }}(value) if field == {{ column.stringify }}
        {% end %}
      {% end %}
      value
    end
  end

  # Registers a normalizer for one or more attributes.
  #
  # * `with:` a proc taking the column's type and returning the same type;
  #   alternatively pass a block, whose parameter is the value.
  # * `apply_to_nil: true` also runs the normalizer for `nil` (the proc or block
  #   then receives a nilable value). The default skips `nil`.
  # * `if:` (Grant-specific) names a predicate method; such a normalizer runs in
  #   `before_validation` instead of the setter, because the predicate needs the
  #   record, and is not applied to query conditions. Only these conditional
  #   normalizers honor `valid?(skip_normalization: true)`.
  #
  # The columns must be declared in the same class. The typed methods are
  # generated once the class body is complete, so declaration order does not
  # matter.
  macro normalizes(*attributes, **options, &block)
    {% normalizer = options[:with] %}
    {% if !normalizer && !block %}
      {% raise "normalizes requires a `with:` proc or a block" %}
    {% end %}
    {% if attributes.empty? %}
      {% raise "normalizes requires at least one attribute" %}
    {% end %}
    {% apply_to_nil = options[:apply_to_nil] %}

    {% for attribute in attributes %}
      # :nodoc:
      def self.{{ options[:if] ? "__conditional_normalize_".id : "__normalize_".id }}{{ attribute.id }}(value)
        {% unless apply_to_nil %}
          return value if value.nil?
        {% end %}
        {% if normalizer %}
          {{ normalizer }}.call(value)
        {% else %}
          {% arg = block.args.size > 0 ? block.args[0] : "value".id %}
          {% if arg.stringify != "value" %}
            {{ arg }} = value
          {% end %}
          {{ block.body }}
        {% end %}
      end

      {% if options[:if] %}
        before_validation :_normalize_{{ attribute.id }}

        private def _normalize_{{ attribute.id }}
          return if @_skip_normalization
          return unless {{ options[:if].id }}
          if current = self.{{ attribute.id }}
            self.{{ attribute.id }} = self.class.__conditional_normalize_{{ attribute.id }}(current)
          end
        end
      {% else %}
        private def __assign_hook_{{ attribute.id }}(value)
          self.class.__normalize_{{ attribute.id }}(value)
        end
      {% end %}
    {% end %}
  end
end

abstract class Grant::Base
  include Grant::Normalization
  extend Grant::Normalization::ClassMethods
end
