require "./probe_support"

def assert_post_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "unscope must return the model query builder" %}
  {% end %}
end

assert_post_builder(GrantAPICardProbeModels::Post.all.unscope(:where))
