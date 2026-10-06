require "./probe_support"

def assert_find_bang_result(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "Post.find! must return Post" %}
  {% end %}
end

assert_find_bang_result(GrantAPICardProbeModels::Post.find!(1_i64))
