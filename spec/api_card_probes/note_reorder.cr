require "./probe_support"

def assert_reorder_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "reorder must return the model query builder" %}
  {% end %}
end

assert_reorder_builder(GrantAPICardProbeModels::Post.where(id: 1_i64).reorder(title: :asc, score: :desc))
