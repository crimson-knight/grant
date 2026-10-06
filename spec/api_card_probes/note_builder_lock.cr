require "./probe_support"

def lock_when_mode_is_present(
  query : Grant::Query::Builder(GrantAPICardProbeModels::Post),
  mode : Grant::Locking::LockMode?,
) : Grant::Query::Builder(GrantAPICardProbeModels::Post)
  if selected_mode = mode
    query.lock!(selected_mode)
  else
    query
  end
end

def assert_builder_lock_returns_same_type(value : T) forall T
  {% unless T == Grant::Query::Builder(GrantAPICardProbeModels::Post) %}
    {% raise "builder lock operations must return the same query-builder type" %}
  {% end %}
end

assert_builder_lock_returns_same_type(GrantAPICardProbeModels::Post.all.lock(true))
assert_builder_lock_returns_same_type(GrantAPICardProbeModels::Post.all.lock(Grant::Locking.clause("FOR UPDATE")))
assert_builder_lock_returns_same_type(GrantAPICardProbeModels::Post.all.lock!(Grant::Locking::LockMode::Update))
assert_builder_lock_returns_same_type(lock_when_mode_is_present(GrantAPICardProbeModels::Post.all, nil))
