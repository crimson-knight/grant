require "./probe_support"

def assert_raw_update_all_result(value : T) forall T
  {% unless T == DB::ExecResult %}
    {% raise "raw SQL update_all must return DB::ExecResult" %}
  {% end %}
end

def assert_parameterized_update_all_returns_count(value : Int64) : Nil
end

assert_raw_update_all_result(GrantAPICardProbeModels::Post.all.update_all("title = 'updated'"))
assert_parameterized_update_all_returns_count(GrantAPICardProbeModels::Post.all.update_all({"title" => "updated"} of String => Grant::Columns::Type))
assert_parameterized_update_all_returns_count(GrantAPICardProbeModels::Post.all.update_all(title: "updated"))
assert_parameterized_update_all_returns_count(GrantAPICardProbeModels::Post.all.update_all([{"title", "updated".as(Grant::Columns::Type)}] of Tuple(String, Grant::Columns::Type)))
assert_parameterized_update_all_returns_count(GrantAPICardProbeModels::Post.all.update_all("title = 'updated'").rows_affected)
