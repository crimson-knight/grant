require "./probe_support"

def assert_post_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "order and reorder must return the model query builder" %}
  {% end %}
end

assert_post_builder(GrantAPICardProbeModels::Post.all.order([:region_id, :line_id]))
assert_post_builder(GrantAPICardProbeModels::Post.all.reorder(published: :asc, score: :asc))
