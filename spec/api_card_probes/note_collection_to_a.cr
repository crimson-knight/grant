require "./probe_support"

def assert_materialized_posts(value : T) forall T
  {% unless T == Array(GrantAPICardProbeModels::Post) %}
    {% raise "Grant collection to_a must return Array(Post)" %}
  {% end %}
end

assert_materialized_posts(GrantAPICardProbeModels::Post.all("WHERE id = ?", [1_i64] of Grant::Columns::Type).to_a)
