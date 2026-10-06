require "./probe_support"

def assert_order_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "order must return the model query builder" %}
  {% end %}
end

assert_order_builder(GrantAPICardProbeModels::Post.where(id: 1_i64).order([:id, :title]))
