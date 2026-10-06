require "./probe_support"

class ParityScratchCompositeRecord < Grant::Base
  table :api_card_probe_parity_scratch_composite_records

  column id : Int64, primary: true
  column tenant_id : Int64
  column local_id : Int64
end

def assert_composite_record(value : T) forall T
  {% unless T == ParityScratchCompositeRecord %}
    {% raise "Grant named criteria lookup must return the model" %}
  {% end %}
end

tenant_id = 1_i64
local_id = 2_i64
assert_composite_record(ParityScratchCompositeRecord.find!(1_i64))
assert_composite_record(ParityScratchCompositeRecord.find_by!(tenant_id: tenant_id, local_id: local_id))
