# Mass assignment of association-valued attributes (`User.new(posts: [post])`,
# `assign_attributes(author: author)`).
#
# Each association macro defines a `_grant_write_assoc_<name>` method on its
# model. This module's dispatcher is generated per model from those methods
# when the mass-assignment entry points (`set_attributes` and what builds on
# it) are compiled, so a model's typed writers are reachable only from there.
# Nothing registers them in a global table.
module Grant::AssociationWriters
  # Applies *value* to the association *association_name* of this record
  # through the association's typed writer. Returns false when the name is not
  # an assignable association or the value has the wrong type. Associations
  # declared on an abstract or STI parent are found too.
  def _grant_assign_association(association_name : String, value : Grant::AssociationRegistry::AssociationValue) : Bool
    {% begin %}
      {% seen = [] of String %}
      case association_name
      {% for owner_type in [@type] + @type.ancestors.select { |ancestor| ancestor.class? && ancestor < Grant::Base } %}
        {% for method in owner_type.methods %}
          {% method_name = method.name.stringify %}
          {% if method_name.starts_with?("_grant_write_assoc_") && !seen.includes?(method_name) %}
            {% seen << method_name %}
      when {{method_name[19..-1]}}
        {{method.name.id}}(value)
          {% end %}
        {% end %}
      {% end %}
      else
        false
      end
    {% end %}
  end
end
