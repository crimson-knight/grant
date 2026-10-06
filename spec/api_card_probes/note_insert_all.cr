require "./probe_support"

class GrantAPICardBulkItem < Grant::Base
  table :api_card_bulk_items

  column id : Int64, primary: true
  column sku : String
  column qty : Int32
end

def assert_insert_all_result(value : T) forall T
  {% unless T == Array(GrantAPICardBulkItem) %}
    {% raise "insert_all must return an array of model instances" %}
  {% end %}
end

attributes = {} of (String | Symbol) => Grant::Columns::Type
attributes[:sku] = "c"
attributes[:qty] = 1_i32
assert_insert_all_result(GrantAPICardBulkItem.insert_all([attributes]))
