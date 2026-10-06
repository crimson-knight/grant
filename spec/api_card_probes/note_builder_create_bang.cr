require "./probe_support"

def assert_created_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "Post.create! must return Post" %}
  {% end %}
end

assert_created_post(GrantAPICardProbeModels::Post.create!(title: "Draft", author_id: nil))
