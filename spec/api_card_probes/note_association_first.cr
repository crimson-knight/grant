require "./probe_support"

def assert_optional_associated_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::PostOrNil %}
    {% raise "AssociationCollection#first must return an optional target model" %}
  {% end %}
end

owner = GrantAPICardProbeModels::User.new
association = Grant::AssociationCollection(GrantAPICardProbeModels::User, GrantAPICardProbeModels::Post).new(owner, :author_id)
assert_optional_associated_post(association.first)
