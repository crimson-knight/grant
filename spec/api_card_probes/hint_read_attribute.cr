require "./probe_support"

def assert_read_attribute_hint_type(value : T) forall T
  {% unless T == Grant::Columns::Type %}
    {% raise "read_attribute must return Grant::Columns::Type" %}
  {% end %}
end

value = GrantAPICardProbeModels::Post.new
if primary_name = value.class.primary_name
  value.read_attribute(primary_name)
end
assert_read_attribute_hint_type(value.read_attribute("id"))
