require "./probe_support"

def assert_builder_build_returns_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "Builder#build must return the model type" %}
  {% end %}
end

assert_builder_build_returns_post(GrantAPICardProbeModels::Post.all.build(title: "draft"))
assert_builder_build_returns_post(GrantAPICardProbeModels::Post.new(title: "draft"))
