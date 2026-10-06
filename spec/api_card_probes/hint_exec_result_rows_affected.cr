require "./probe_support"

def assert_affected_row_count(value : T) forall T
  {% unless T == Int64 %}
    {% raise "DB::ExecResult#rows_affected must return Int64" %}
  {% end %}
end

relation = GrantAPICardProbeModels::Post.all
sql = "title = 'updated'"
updated = 0_i64
assert_affected_row_count(relation.update_all(sql).rows_affected)
updated += relation.update_all(sql).rows_affected
