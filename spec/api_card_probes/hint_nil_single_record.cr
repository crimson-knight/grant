require "./probe_support"

class W6TimeOrder < Grant::Base
  table :api_card_probe_w6_time_orders

  column id : Int64, primary: true
  column label : String
end

def assert_time_order_label(value : T) forall T
  {% unless T == String %}
    {% raise "narrowing a Grant find result must expose the model field type" %}
  {% end %}
end

id = 1_i64
if order = W6TimeOrder.find(id)
  assert_time_order_label(order.label)
end
