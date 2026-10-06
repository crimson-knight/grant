require "./probe_support"

def assert_unscope_returns_post_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "unscope must return the same Post query-builder type" %}
  {% end %}
end

assert_unscope_returns_post_builder(GrantAPICardProbeModels::Post.all.unscope(:where))
assert_unscope_returns_post_builder(GrantAPICardProbeModels::Post.all.unscope(where: :column))
