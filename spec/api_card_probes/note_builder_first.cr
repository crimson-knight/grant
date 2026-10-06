require "./probe_support"

def assert_builder_first_is_nilable(value : T) forall T
  {% unless T == GrantAPICardProbeModels::PostOrNil %}
    {% raise "Builder#first must return Post or Nil" %}
  {% end %}
end

def assert_builder_first_bang_returns_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "Builder#first! must return Post" %}
  {% end %}
end

assert_builder_first_is_nilable(GrantAPICardProbeModels::Post.all.first)
assert_builder_first_bang_returns_post(GrantAPICardProbeModels::Post.all.first!)
