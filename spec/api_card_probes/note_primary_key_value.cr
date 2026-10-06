require "./probe_support"

def assert_primary_key_value(value : T) forall T
  {% unless T == GrantAPICardProbeModels::NullableInt64 %}
    {% raise "primary_key_value must be nilable Int64" %}
  {% end %}
end

assert_primary_key_value(GrantAPICardProbeModels::Post.new.primary_key_value)
