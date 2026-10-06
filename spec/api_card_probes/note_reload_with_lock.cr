require "./probe_support"

def assert_reload_with_lock_returns_post(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "reload_with_lock must return the same Post model" %}
  {% end %}
end

assert_reload_with_lock_returns_post(GrantAPICardProbeModels::Post.new(title: "probe").reload_with_lock(Grant::Locking::LockMode::Update, force: true))
assert_reload_with_lock_returns_post(GrantAPICardProbeModels::Post.new(title: "probe").reload_with_lock)
