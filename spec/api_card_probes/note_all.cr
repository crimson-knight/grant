require "./probe_support"

def assert_no_argument_all(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "Post.all must return a query builder" %}
  {% end %}
end

def assert_raw_all(value : T) forall T
  {% unless T == GrantAPICardProbeModels::ListOfPosts %}
    {% raise "raw Post.all must return an array or Grant collection" %}
  {% end %}
end

assert_no_argument_all(GrantAPICardProbeModels::Post.all)
assert_raw_all(GrantAPICardProbeModels::Post.all("WHERE id = ?", [1_i64] of Grant::Columns::Type))
