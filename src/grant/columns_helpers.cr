# Helper methods for column introspection
module Grant::ColumnsHelpers
  module ClassMethods
    # Get column information for a given attribute name
    def column_for_attribute(attribute_name : String) : NamedTuple(name: String, column_type: Class, nilable: Bool)?
      {% begin %}
        case attribute_name
        {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
          {% ann = ivar.annotation(Grant::Column) %}
          when {{ivar.name.stringify}}
            {
              name: {{ivar.name.stringify}}, 
              column_type: {{ann[:nilable] ? ivar.type : ivar.type.union_types.reject { |t| t == Nil }.first}},
              nilable: {{ann[:nilable] || false}}
            }
        {% end %}
        else
          nil
        end
      {% end %}
    end

    # Get all column information
    def columns_info : Array(NamedTuple(name: String, column_type: Class, nilable: Bool))
      {% begin %}
        [
          {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
            {% ann = ivar.annotation(Grant::Column) %}
            {
              name: {{ivar.name.stringify}}, 
              column_type: {{ann[:nilable] ? ivar.type : ivar.type.union_types.reject { |t| t == Nil }.first}},
              nilable: {{ann[:nilable] || false}}
            },
          {% end %}
        ]
      {% end %}
    end
  end
end

# Include in Base
abstract class Grant::Base
  extend Grant::ColumnsHelpers::ClassMethods

  # Instance method to read any attribute by name
  def read_attribute(name : String) : Grant::Columns::Type
    {% begin %}
      case name
      {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        when {{ivar.name.stringify}}
          @{{ivar.id}}.as(Grant::Columns::Type)
      {% end %}
      else
        raise "Unknown attribute: #{name}"
      end
    {% end %}
  end

  # Instance method to write any attribute by name
  def write_attribute(name : String, value : Grant::Columns::Type) : Nil
    {% begin %}
      case name
      {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        when {{ivar.name.stringify}}
          if value.is_a?({{ivar.type}})
            @{{ivar.id}} = value
          else
            raise "Type mismatch for {{ivar.name}}: expected {{ivar.type}} but got #{value.class}"
          end
      {% end %}
      else
        raise "Unknown attribute: #{name}"
      end
    {% end %}
  end

  # Clears a named column when its declared type accepts nil. Association
  # setters use this so clearing a belongs_to remains valid for models that
  # declare a required, non-null foreign key.
  def clear_nullable_attribute(name : String) : Nil
    {% begin %}
      case name
      {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
        {% ann = ivar.annotation(Grant::Column) %}
        {% if ann[:nilable] %}
          when {{ivar.name.stringify}}
            self.{{ivar.name.id}} = nil
        {% end %}
      {% end %}
      else
        nil
      end
    {% end %}
  end
end
