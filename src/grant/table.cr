# Adds a :nodoc: to grant methods/constants if `DISABLE_GRANTE_DOCS` ENV var is true
macro disable_grant_docs?(stmt)
  {% unless flag?(:grant_docs) %}
    # :nodoc:
    {{stmt.id}}
  {% else %}
    {{stmt.id}}
  {% end %}
end

module Grant::Tables
  module ClassMethods
    def primary_name
      {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% if pk = primary_key %}
        {{pk.name.stringify}}
      {% end %}
    {% end %}
    end

    def primary_type
      {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% if pk = primary_key %}
        {{pk.type}}
      {% end %}
    {% end %}
    end

    def quoted_table_name : String
      self.adapter.quote(table_name)
    end

    def quote(column_name) : String
      self.adapter.quote(column_name)
    end

    # Returns the name of the table for `self`
    # defaults to the model's name underscored + 's'.
    def table_name : String
      {% begin %}
        {% table_ann = @type.annotation(Grant::Table) %}
        {{table_ann && !table_ann[:name].nil? ? table_ann[:name] : @type.name.underscore.stringify.split("::").last}}
      {% end %}
    end
  end

  macro table(name)
    @[Grant::Table(name: {{(name.is_a?(StringLiteral) ? name : name.id.stringify) || nil}})]
    class ::{{@type.name.id}}; end
  end
end
