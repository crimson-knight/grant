require "./probe_support"

def assert_builder_count(value : T) forall T
  {% unless T == Grant::Query::Builder::CountResult %}
    {% raise "builder count must return CountResult" %}
  {% end %}
end

assert_builder_count(GrantAPICardProbeModels::Post.where(id: 1_i64).count)
