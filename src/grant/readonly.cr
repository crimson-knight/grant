require "./exceptions"

module Grant
  # Raised when a column declared with `attr_readonly` is assigned on a
  # persisted record. It is a `ReadOnlyRecordError`, so code rescuing that class
  # for `update_columns` keeps working.
  #
  # Mirrors ActiveRecord's `ActiveRecord::ReadonlyAttributeError`.
  class ReadonlyAttributeError < ReadOnlyRecordError
    getter attribute : String

    def initialize(model_name : String, @attribute : String)
      super("#{model_name}##{@attribute} is marked as readonly")
    end
  end
end

# Column-level read-only support: `attr_readonly`.
#
# ```
# class User < Grant::Base
#   column id : Int64, primary: true
#   column login : String
#   attr_readonly :login
# end
#
# user = User.create!(login: "ada") # writable while the record is new
# user.login = "grace"              # raises Grant::ReadonlyAttributeError
# ```
module Grant::Readonly
  module ClassMethods
    # True when *attribute_name* was declared with `attr_readonly`.
    def readonly_attribute?(attribute_name : String) : Bool
      false
    end

    # True when assigning a readonly column on a persisted record raises.
    # Models opt out with `attr_readonly :slug, raise_on_assign: false`, which
    # restores the older behavior of accepting the assignment in memory and
    # leaving it out of the `UPDATE`.
    def raise_on_readonly_assign? : Bool
      true
    end
  end

  # Marks one or more columns as read-only. Read-only columns are writable when
  # a record is first created, but assigning them on a persisted record raises
  # `Grant::ReadonlyAttributeError`, they are excluded from `UPDATE` statements,
  # and `update_columns` rejects them. Mirrors ActiveRecord's `attr_readonly`.
  #
  # Pass `raise_on_assign: false` to keep the assignment silent (it stays in
  # memory, is never written).
  #
  # ```
  # class User < Grant::Base
  #   column login : String
  #   attr_readonly :login
  # end
  # ```
  macro attr_readonly(*fields, **options)
    # Accumulate declared read-only columns in a per-class constant so multiple
    # `attr_readonly` calls (and inheritance) compose correctly. Each call
    # redefines the class methods to cover the full, deduplicated set.
    {% if @type.has_constant?(:GRANT_READONLY_ATTRIBUTES) %}
      {% for field in fields %}
        {% GRANT_READONLY_ATTRIBUTES << field.id.stringify %}
      {% end %}
    {% else %}
      GRANT_READONLY_ATTRIBUTES = [
        {% for field in fields %}
          {{ field.id.stringify }},
        {% end %}
      ] of String
    {% end %}

    def self.readonly_attributes : Array(String)
      GRANT_READONLY_ATTRIBUTES.uniq
    end

    def self.readonly_attribute?(attribute_name : String) : Bool
      GRANT_READONLY_ATTRIBUTES.includes?(attribute_name)
    end

    {% if options[:raise_on_assign] == false %}
      def self.raise_on_readonly_assign? : Bool
        false
      end
    {% end %}
  end

  # Called by every generated column writer. New records may assign anything;
  # a persisted record raises for a readonly column.
  #
  # :nodoc:
  def __guard_readonly_attribute!(attribute_name : String) : Nil
    return if new_record?
    return unless self.class.readonly_attribute?(attribute_name)
    return unless self.class.raise_on_readonly_assign?
    raise Grant::ReadonlyAttributeError.new(self.class.name, attribute_name)
  end
end
