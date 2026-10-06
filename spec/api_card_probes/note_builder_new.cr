require "./probe_support"

def assert_model_constructor_result(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "Post.new must construct a Post model" %}
  {% end %}
end

def assert_model_relation_result(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "Post.all must return a Post query builder" %}
  {% end %}
end

assert_model_constructor_result(GrantAPICardProbeModels::Post.new)
assert_model_relation_result(GrantAPICardProbeModels::Post.all)
