require "./probe_support"

class GrantAPICardRequiredPrimaryKey < Grant::Base
  table :api_card_required_primary_keys
  column id : Int64, primary: true
end

def assert_required_id_type(value : T) forall T
  {% unless T == Int64 %}
    {% raise "the declared primary-key getter must return Int64" %}
  {% end %}
end

assert_required_id_type(GrantAPICardRequiredPrimaryKey.new.id!)
