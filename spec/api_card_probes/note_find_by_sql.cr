require "./probe_support"

def assert_find_by_sql_result(value : T) forall T
  {% unless T == Array(GrantAPICardProbeModels::Post) %}
    {% raise "find_by_sql must return Array(Post)" %}
  {% end %}
end

assert_find_by_sql_result(GrantAPICardProbeModels::Post.find_by_sql("SELECT * FROM api_card_probe_posts", [] of Grant::Columns::Type))
