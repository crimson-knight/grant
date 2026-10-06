require "./probe_support"

def assert_model_count(value : T) forall T
  {% unless T == Int64 %}
    {% raise "model count must return Int64" %}
  {% end %}
end

assert_model_count(GrantAPICardProbeModels::Post.count)
