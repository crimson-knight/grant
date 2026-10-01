require "../../support/m03_fixture"
require "../../support/test_connection"

class W6bGuardedRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_guarded_rows

  column id : Int64, primary: true
  column name : String?
end

private def w6b_context(environment : String?, protected_environments : Array(String) = Grant::Schema::InternalMetadata::DEFAULT_PROTECTED)
  Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false, environment: environment,
    protected_environments: protected_environments)
end

# ar_internal_metadata wired into the migration context, the model migrator
# and the database tasks.
describe "ar_internal_metadata environment protection, wired" do
  before_each do
    TestConnection.ensure_registered
    M03Fixture.reset!
  end

  after_all do
    M03Fixture.reset!
    W6bGuardedRow.migrator.drop
  end

  it "records the environment on migrate and checks it afterwards" do
    context = w6b_context("development")
    context.recorded_environment.should be_nil
    context.migrate
    context.recorded_environment.should eq "development"
    context.check_protected_environments!
    expect_raises(Grant::Schema::EnvironmentMismatchError, /development/) { w6b_context("test").check_protected_environments! }
    w6b_context("test").check_protected_environments!(force: true)
  end

  it "refuses a protected environment, recorded or only named" do
    w6b_context("production").migrate
    error = expect_raises(Grant::Schema::ProtectedEnvironmentError) { w6b_context("production").check_protected_environments! }
    error.environment.should eq "production"
    # A context that names no environment still sees what the database recorded.
    expect_raises(Grant::Schema::ProtectedEnvironmentError) { w6b_context(nil).check_protected_environments! }
    w6b_context(nil).check_protected_environments!(force: true)
    w6b_context("production", protected_environments: ["prod"]).check_protected_environments!
  end

  it "protects a database that recorded nothing by the environment the context names" do
    expect_raises(Grant::Schema::ProtectedEnvironmentError) { w6b_context("production").check_protected_environments! }
    w6b_context("development").check_protected_environments!
    w6b_context(nil).check_protected_environments!
  end

  it "re-records the environment with set_environment!" do
    w6b_context("development").migrate
    w6b_context("staging").set_environment!
    w6b_context("staging").recorded_environment.should eq "staging"
    w6b_context("staging").check_protected_environments!
    expect_raises(Grant::Schema::InvalidMigration) { w6b_context(nil).set_environment! }
  end

  it "blocks Model.migrator.drop_and_create on a database recorded as production" do
    W6bGuardedRow.migrator.drop_and_create
    W6bGuardedRow.create(name: "kept")
    Grant::Schema::InternalMetadata.new(M03Fixture.adapter).record_environment("production")
    expect_raises(Grant::Schema::ProtectedEnvironmentError) { W6bGuardedRow.migrator.drop_and_create }
    W6bGuardedRow.count.should eq 1
    W6bGuardedRow.migrator.drop_and_create(force: true)
    W6bGuardedRow.count.should eq 0
  end

  it "lets drop_and_create run on development databases and checks a named environment" do
    W6bGuardedRow.migrator.drop_and_create
    Grant::Schema::InternalMetadata.new(M03Fixture.adapter).record_environment("development")
    W6bGuardedRow.migrator.drop_and_create
    W6bGuardedRow.migrator.drop_and_create(environment: "development")
    expect_raises(Grant::Schema::EnvironmentMismatchError) { W6bGuardedRow.migrator.drop_and_create(environment: "test") }
  end

  it "has no effect without a metadata table" do
    M03Fixture.table?("ar_internal_metadata").should be_false
    W6bGuardedRow.migrator.drop_and_create
    M03Fixture.table?("ar_internal_metadata").should be_false
  end
end
