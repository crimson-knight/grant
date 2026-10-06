require "./probe_support"

def assert_concrete_primary_name(value : T) forall T
  {% unless T == String %}
    {% raise "a model primary_name with a key must be String" %}
  {% end %}
end

def assert_base_primary_name(value : T) forall T
  {% unless T == Nil %}
    {% raise "Grant::Base.primary_name without a key must be Nil" %}
  {% end %}
end

assert_concrete_primary_name(GrantAPICardProbeModels::Post.primary_name)
assert_base_primary_name(Grant::Base.primary_name)
