require "./probe_support"

def assert_instance_delete_returns_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "instance delete must return the same Post model" %}
  {% end %}
end

assert_instance_delete_returns_post(GrantAPICardProbeModels::Post.new(title: "draft").delete)

def assert_destroy_returns_bool(value : Bool) : Nil
end

assert_destroy_returns_bool(GrantAPICardProbeModels::Post.new(title: "draft").destroy)
