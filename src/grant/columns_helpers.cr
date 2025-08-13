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
        {% ann = ivar.annotation(Grant::Column) %}
        when {{ivar.name.stringify}}
          @{{ivar.id}} = value.as({{ann[:nilable] ? ivar.type : ivar.type.union_types.reject { |t| t == Nil }.first}})
      {% end %}
      else
        raise "Unknown attribute: #{name}"
      end
    {% end %}
  end
end