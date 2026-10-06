require "./probe_support"

def assert_from_builder(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "from must return the model query builder" %}
  {% end %}
end

assert_from_builder(GrantAPICardProbeModels::Post.where(id: 1_i64).from("api_card_probe_posts", as: "probe_posts"))
