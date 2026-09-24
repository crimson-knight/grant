require "../spec_helper"

class GrantConventionsRegistryProbe < Grant::Base
  table grant_conventions_registry_probes

  column id : Int64, primary: true
end

class LegacyConnectionConfigProbe < Grant::Base
  connection_config(failover_retry_attempts: 4)

  column id : Int64, primary: true
end

private def grant_conventions_registry_attribute : Grant::Encryption::EncryptedAttribute
  writer = ->(_record : Grant::Base, _value : String?) : Nil { nil }
  Grant::Encryption::EncryptedAttribute.new(GrantConventionsRegistryProbe, "secret", false, writer)
end

describe "Grant convention regressions" do
  it "returns an isolated encrypted attribute registry snapshot" do
    model_name = "Unregistered_#{UUID.random}"
    snapshot = Grant::Encryption::EncryptedAttributeRegistry.for(model_name)
    snapshot["secret"] = grant_conventions_registry_attribute

    Grant::Encryption::EncryptedAttributeRegistry.for(model_name).has_key?("secret").should be_false
  end

  it "uses one Grant error base for new public errors" do
    Grant::NoTenantError.new("tenant required").is_a?(Grant::ErrorBase).should be_true
    Grant::TenantMismatchError.new("tenant mismatch").is_a?(Grant::ErrorBase).should be_true
    Grant::Querying::ScopedRawSqlError.new("scoped SQL").is_a?(Grant::ErrorBase).should be_true
    Grant::UnsupportedSchemaTenantAdapterError.new("adapter").is_a?(Grant::ErrorBase).should be_true
    Grant::SchemaTenantConnectionMismatchError.new("connection").is_a?(Grant::ErrorBase).should be_true
    Grant::SchemaTenantResetError.new("reset", cause: Grant::ErrorBase.new("database reset failed")).is_a?(Grant::ErrorBase).should be_true
    Grant::StrictLoadingViolationError.new("association").is_a?(Grant::ErrorBase).should be_true
    Grant::Transaction::PreservedIOError.new(IO::Error.new("read failed")).is_a?(Grant::ErrorBase).should be_true
  end

  it "keeps the deprecated connection_config macro available" do
    LegacyConnectionConfigProbe.failover_retry_attempts.should eq(4)
  end
end
