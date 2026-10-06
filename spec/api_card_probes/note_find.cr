require "./probe_support"

def assert_find_result(value : T) forall T
  {% unless T == GrantAPICardProbeModels::PostOrNil %}
    {% raise "Post.find must return Post or Nil" %}
  {% end %}
end

assert_find_result(GrantAPICardProbeModels::Post.find(1_i64))
