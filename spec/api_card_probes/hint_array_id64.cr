require "./probe_support"

def assert_int64_id(value : T) forall T
  {% unless T == Int64 %}
    {% raise "a Grant raising ID getter must return Int64" %}
  {% end %}
end

def assert_int64_array(value : T) forall T
  {% unless T == Array(Int64) %}
    {% raise "the ID accumulator must remain Array(Int64)" %}
  {% end %}
end

record = GrantAPICardProbeModels::Post.new
ids = [] of Int64
if record_id = record.id
  ids << record_id
end
assert_int64_array(ids)

ids_from_each = [] of Int64
assert_int64_id(record.id!)
ids_from_each << record.id!
assert_int64_array(ids_from_each)
