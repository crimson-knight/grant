require "./probe_support"

class GrantAPICardCompositeKeyProbe < Grant::Base
  table :api_card_composite_key_probes
  include Grant::CompositePrimaryKey

  column shop_id : Int64, primary: true
  column order_id : Int64, primary: true

  composite_primary_key shop_id, order_id
end

def assert_composite_primary_key_flag(value : T) forall T
  {% unless T == Bool %}
    {% raise "composite_primary_key? must return Bool" %}
  {% end %}
end

assert_composite_primary_key_flag(GrantAPICardCompositeKeyProbe.composite_primary_key?)
