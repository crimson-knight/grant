require "./probe_support"

def assert_required_post_result(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "a required query result must be Post" %}
  {% end %}
end

posts = GrantAPICardProbeModels::Post.all
assert_required_post_result(posts.find! { |post| post.id == 1_i64 })
assert_required_post_result(posts.where(id: 1_i64).first || raise "Post missing")
