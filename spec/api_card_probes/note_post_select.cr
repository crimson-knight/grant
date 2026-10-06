require "./probe_support"

alias GrantAPICardPluckResult = Array(Grant::Columns::Type)

def assert_post_select_result(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "Post.select(:title) must return a Post query builder" %}
  {% end %}
end

def assert_post_pluck_result(value : T) forall T
  {% unless T == GrantAPICardPluckResult %}
    {% raise "Post.pluck(:title) must return GrantAPICardPluckResult" %}
  {% end %}
end

assert_post_select_result(GrantAPICardProbeModels::Post.select(:title))
assert_post_pluck_result(GrantAPICardProbeModels::Post.pluck(:title))
