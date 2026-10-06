require "./probe_support"

def assert_builder_max_result(value : T) forall T
  {% unless T == Grant::Query::Builder::ExtremumResult %}
    {% raise "Builder#max must return ExtremumResult" %}
  {% end %}
end

assert_builder_max_result(GrantAPICardProbeModels::Post.all.max(:score))
assert_builder_max_result(GrantAPICardProbeModels::Post.all.max("score"))
assert_builder_max_result(GrantAPICardProbeModels::Post.all.group(:status).max(:score))

def assert_first_row_is_optional_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::PostOrNil %}
    {% raise "ordered first must return Post or Nil" %}
  {% end %}
end

assert_first_row_is_optional_post(GrantAPICardProbeModels::Post.all.reorder(score: :desc).first)
