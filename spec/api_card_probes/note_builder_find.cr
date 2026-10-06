require "./probe_support"

def assert_optional_post_result(value : T) forall T
  {% unless T == GrantAPICardProbeModels::PostOrNil %}
    {% raise "builder find and first must return an optional Post" %}
  {% end %}
end

posts = GrantAPICardProbeModels::Post.all
assert_optional_post_result(posts.find { |post| post.id == 1_i64 })
assert_optional_post_result(posts.where(id: 1_i64).first)
