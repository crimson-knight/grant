require "./probe_support"

def api_card_hint_result_set : DB::ResultSet
  raise "This compile-only probe does not execute."
end

def assert_from_rs_hint_type(value : T) forall T
  {% unless T == Int64 %}
    {% raise "Grant::Type.from_rs with Int64 must return Int64" %}
  {% end %}
end

result = api_card_hint_result_set
assert_from_rs_hint_type(Grant::Type.from_rs(result, Int64))

struct GrantAPICardHintConverter
  def to_db(values : Array(String)) : Array(String)
    values
  end
end

def assert_to_db_hint_type(value : T) forall T
  {% unless T == Array(String) %}
    {% raise "to_db must return Array(String)" %}
  {% end %}
end

converter = GrantAPICardHintConverter.new
values = [] of String
assert_to_db_hint_type(converter.to_db(values))
