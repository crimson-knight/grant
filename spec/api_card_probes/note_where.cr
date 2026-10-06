require "./probe_support"

def assert_where_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "where must return the model query builder" %}
  {% end %}
end

assert_where_builder(GrantAPICardProbeModels::Post.where(id: 1_i64))
