require "./probe_support"

def assert_only_returns_post_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "only must return the same Post query-builder type" %}
  {% end %}
end

assert_only_returns_post_builder(GrantAPICardProbeModels::Post.all.only(:where))
assert_only_returns_post_builder(GrantAPICardProbeModels::Post.all.only(:nonsense))
