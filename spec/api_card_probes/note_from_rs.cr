require "./probe_support"

def api_card_probe_result_set : DB::ResultSet
  raise "This compile-only probe does not execute."
end

def assert_converted_int64(value : T) forall T
  {% unless T == Int64 %}
    {% raise "Grant::Type.from_rs with Int64 must return Int64" %}
  {% end %}
end

assert_converted_int64(Grant::Type.from_rs(api_card_probe_result_set, Int64))
