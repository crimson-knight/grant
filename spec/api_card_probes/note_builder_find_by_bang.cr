require "./probe_support"

def assert_builder_find_by_bang_returns_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "Builder#find_by! must return the model type" %}
  {% end %}
end

assert_builder_find_by_bang_returns_post(GrantAPICardProbeModels::Post.where(title: "draft").find_by!(title: "draft"))
