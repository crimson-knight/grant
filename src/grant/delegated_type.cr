# Delegated types for Grant — a superclass record that hands its type-specific
# data to one of several concrete records, each in its own table.
#
# `delegated_type` is ActiveRecord's `delegated_type`. It declares a
# polymorphic `belongs_to` and generates a compile-time exhaustive set of
# predicates, readers and builders over the closed list of types you give it.
# Everything that only inspects the stored type string (`message?`,
# `entryable_name`, `message_id`, ...) never touches the database; the readers
# load the target at most once, through the ordinary association cache, so
# `includes(:entryable)` preloads with one IN query per stored type.
#
# ```
# class Entry < Grant::Base
#   connection sqlite
#   column id : Int64, primary: true
#   delegated_type :entryable, types: {Message, Comment}, dependent: :destroy
# end
#
# class Message < Grant::Base
#   column id : Int64, primary: true
#   column body : String
# end
#
# entry = Entry.new
# entry.build_entryable(Message, body: "Hello")
# entry.message?       # => true
# entry.message        # => the Message
# entry.comment        # => nil
# entry.entryable_name # => "message"
# ```
#
# For `delegated_type :entryable, types: {Message, Comment}` Grant generates:
#
# * everything `belongs_to :entryable, polymorphic: true` generates
#   (`entryable_id`, `entryable_type`, `entryable`, `entryable=`, ...),
# * `#entryable_class` — the target class named by `entryable_type`
#   (`nil` when unset; raises `Grant::DelegatedType::UnknownTypeError` for a
#   type outside the list),
# * `#entryable_name` — the snake_case name of the target class (`"message"`),
# * `#message?` / `#comment?` — compare the stored type string,
# * `#message` / `#comment` — the target when the type matches, else `nil`,
# * `#message_id` / `#comment_id` — the foreign key when the type matches,
# * `#build_entryable(Message, **attrs)` — builds and assigns a target of the
#   given class, and `#build_entryable(**attrs)` builds one of the current type,
# * `.messages` / `.comments` — relations restricted to one type.
#
# Options: `types:` (required) lists the concrete classes; `dependent: :destroy`
# or `:delete` removes the target after the superclass row is destroyed; every
# other option (`optional:`, `touch:`, `foreign_key:`, `type_column:`,
# `strict_loading:`, ...) goes to the polymorphic `belongs_to`.
module Grant::DelegatedType
  # Raised when a record's stored type is not one of its `delegated_type` types.
  class UnknownTypeError < Grant::ErrorBase
    def initialize(role : String, type_name : String)
      super("#{type_name} is not a delegated type of #{role}")
    end
  end

  # Raised when a type-dependent call needs a type but none is stored.
  class TypeNotSetError < Grant::ErrorBase
    def initialize(role : String)
      super("#{role}_type is not set")
    end
  end

  # Declares the delegated type *role* over the classes in *types*.
  macro delegated_type(role, types, dependent = nil, **options)
    {% unless types.is_a?(TupleLiteral) || types.is_a?(ArrayLiteral) %}
      {% raise "delegated_type #{role.id}: `types:` must be a tuple of classes, e.g. {Message, Comment}" %}
    {% end %}
    {% if types.empty? %}
      {% raise "delegated_type #{role.id}: `types:` must name at least one class" %}
    {% end %}
    {% unless dependent.nil? || dependent == :destroy || dependent == :delete %}
      {% raise "delegated_type #{role.id}: `dependent:` supports :destroy and :delete, got #{dependent}" %}
    {% end %}
    {% foreign_key = options[:foreign_key] || (role.id.stringify + "_id") %}
    {% type_column = options[:type_column] || (role.id.stringify + "_type") %}
    {% fk_name = foreign_key.is_a?(TypeDeclaration) ? foreign_key.var.stringify : foreign_key.id.stringify %}
    {% type_name = type_column.id.stringify %}

    belongs_to {{role}}, polymorphic: true{% for key, value in options %}, {{key.id}}: {{value}}{% end %}

    # The class named by the stored type, `nil` when no type is stored.
    def {{role.id}}_class : ({% for t, i in types %}{{t}}.class{% if i < types.size - 1 %} | {% end %}{% end %})?
      case stored = self.{{type_name.id}}
      when nil
        nil
      {% for t in types %}
      when {{t}}.polymorphic_name
        {{t}}
      {% end %}
      else
        raise Grant::DelegatedType::UnknownTypeError.new({{role.id.stringify}}, stored)
      end
    end

    # The snake_case name of the stored type (`"message"`), `nil` when unset.
    def {{role.id}}_name : String?
      case stored = self.{{type_name.id}}
      when nil
        nil
      {% for t in types %}
      when {{t}}.polymorphic_name
        {{t.resolve.name.stringify.gsub(/::/, "_").underscore}}
      {% end %}
      else
        raise Grant::DelegatedType::UnknownTypeError.new({{role.id.stringify}}, stored)
      end
    end

    # Builds a *klass* target from *attrs* and assigns it.
    {% for t in types %}
    def build_{{role.id}}(klass : {{t}}.class, **attrs) : {{t}}
      record = {{t}}.new(**attrs)
      self.{{role.id}} = record
      record
    end
    {% end %}

    # Builds a target of the currently stored type from *attrs* and assigns it.
    def build_{{role.id}}(**attrs)
      case klass = {{role.id}}_class
      {% for t in types %}
      when {{t}}.class
        build_{{role.id}}({{t}}, **attrs)
      {% end %}
      else
        raise Grant::DelegatedType::TypeNotSetError.new({{role.id.stringify}})
      end
    end

    {% for t in types %}
      {% short = t.resolve.name.stringify.gsub(/::/, "_").underscore %}
      {% if short.ends_with?("y") && !"aeiou".includes?(short[-2..-2]) %}
        {% plural = short[0..-2] + "ies" %}
      {% elsif short.ends_with?("s") || short.ends_with?("x") || short.ends_with?("z") || short.ends_with?("ch") || short.ends_with?("sh") %}
        {% plural = short + "es" %}
      {% else %}
        {% plural = short + "s" %}
      {% end %}
      # True when the stored type is {{t}}; compares strings, no query.
      def {{short.id}}? : Bool
        self.{{type_name.id}} == {{t}}.polymorphic_name
      end

      # The {{t}} target when the stored type matches, else `nil`.
      def {{short.id}} : {{t}}?
        return nil unless {{short.id}}?
        {{role.id}}.as?({{t}})
      end

      # The foreign key when the stored type is {{t}}, else `nil`.
      def {{short.id}}_id
        self.{{fk_name.id}} if {{short.id}}?
      end

      # Rows whose stored type is {{t}}.
      def self.{{plural.id}}
        where({{type_name}}, :eq, {{t}}.polymorphic_name)
      end
    {% end %}

    {% if dependent %}
      after_destroy do
        stored_type = self.{{type_name.id}}
        stored_key = self.read_attribute({{fk_name}})
        if stored_type && !stored_key.nil?
          case stored_type
          {% for t in types %}
          when {{t}}.polymorphic_name
            relation = {{t}}.where({{t}}.primary_name, :eq, stored_key)
            {% if dependent == :destroy %}
              if target = relation.first
                target.destroyed_by_association = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{role.id.stringify}})
                target.destroy
              end
            {% else %}
              relation.delete_all
            {% end %}
          {% end %}
          end
        end
      end
    {% end %}
  end
end
