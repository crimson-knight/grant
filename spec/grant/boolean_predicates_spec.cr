require "../spec_helper"

describe "Grant internal boolean predicates" do
  it "uses question predicates for connection and schema state" do
    adapter = Grant::Adapter::Sqlite.new("boolean_predicate", "sqlite3::memory:")
    adapter.open do |connection|
      context = Grant::SchemaTenant::Context.new(adapter, connection, "acme")
      context.usable?.should be_true
    end

    Grant::ConnectionManagement::ReplicaLagTracker.new.written?.should be_false
  end
end
