require "./probe_support"

def assert_required_name(value : T) forall T
  {% unless T == String %}
    {% raise "User#name must be String" %}
  {% end %}
end

def assert_raw_name(value : T) forall T
  {% unless T == GrantAPICardProbeModels::NullableString %}
    {% raise "User#name? must be nilable String" %}
  {% end %}
end

def assert_nullable_nickname(value : T) forall T
  {% unless T == GrantAPICardProbeModels::NullableString %}
    {% raise "User#nickname must be nilable String" %}
  {% end %}
end

def assert_nickname_bang(value : T) forall T
  {% unless T == String %}
    {% raise "User#nickname! must be String" %}
  {% end %}
end

assert_required_name(GrantAPICardProbeModels::User.new.name)
assert_raw_name(GrantAPICardProbeModels::User.new.name?)
assert_nullable_nickname(GrantAPICardProbeModels::User.new.nickname)
assert_nickname_bang(GrantAPICardProbeModels::User.new.nickname!)
