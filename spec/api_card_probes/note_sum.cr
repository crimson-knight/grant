require "./probe_support"

def assert_sum_result(value : T) forall T
  {% unless T == Grant::Query::Builder::SumResult %}
    {% raise "builder sum must return SumResult" %}
  {% end %}
end

assert_sum_result(GrantAPICardProbeModels::Post.where(id: 1_i64).sum(:score))
