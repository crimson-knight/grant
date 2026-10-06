require "./probe_support"

def assert_schema_tenant_reset_error(value : T) forall T
  {% unless T == Grant::SchemaTenantResetError %}
    {% raise "SchemaTenantResetError.new must return that error type" %}
  {% end %}
end

assert_schema_tenant_reset_error(Grant::SchemaTenantResetError.new("reset failed", Exception.new("cause")))
assert_schema_tenant_reset_error(Grant::SchemaTenantResetError.new("reset failed", Exception.new("cause"), Exception.new("block")))
