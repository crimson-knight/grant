require "./probe_support"

post = GrantAPICardProbeModels::Post.all
post = post.only(:where).except(:order).unscope(:where).lock(true)
maximum = post.max(:score)

def assert_post_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "Grant query modifiers must return the model query builder" %}
  {% end %}
end

def assert_extremum_result(value : T) forall T
  {% unless T == Grant::Query::Builder::ExtremumResult %}
    {% raise "Grant builder max must return ExtremumResult" %}
  {% end %}
end

assert_post_builder(post)
assert_extremum_result(maximum)
