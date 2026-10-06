require "./probe_support"

class WithLockSpecAccount < Grant::Base
  table :api_card_probe_with_lock_spec_accounts

  column id : Int64, primary: true
end

def assert_locked_reload(value : T) forall T
  {% unless T == WithLockSpecAccount %}
    {% raise "reload_with_lock must return the same model" %}
  {% end %}
end

record = WithLockSpecAccount.new
mode = Grant::Locking::LockMode::Update
assert_locked_reload(record.reload_with_lock(mode))
