require "./probe_support"

def assert_user_id(value : T) forall T
  {% unless T == GrantAPICardProbeModels::NullableInt64 %}
    {% raise "User#id must be nilable Int64" %}
  {% end %}
end

def assert_user_id_bang(value : T) forall T
  {% unless T == Int64 %}
    {% raise "User#id! must be Int64" %}
  {% end %}
end

assert_user_id(GrantAPICardProbeModels::User.new.id)
assert_user_id_bang(GrantAPICardProbeModels::User.new.id!)
