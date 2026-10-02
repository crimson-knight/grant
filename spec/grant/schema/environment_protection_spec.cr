require "../../support/m03_fixture"

describe "ar_internal_metadata environment protection" do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "records the environment the first time migrations run" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false, environment: "development")
    context.migrate
    metadata = Grant::Schema::InternalMetadata.new(M03Fixture.adapter)
    metadata.environment.should eq "development"
    M03Fixture.table?("ar_internal_metadata").should be_true

    # A later run from another environment does not overwrite it.
    other = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false, environment: "test")
    other.migrate
    metadata.environment.should eq "development"
  end

  it "stores other keys and updates them in place" do
    metadata = Grant::Schema::InternalMetadata.new(M03Fixture.adapter)
    metadata["schema_sha1"].should be_nil
    metadata["schema_sha1"] = "abc"
    metadata["schema_sha1"] = "def"
    metadata["schema_sha1"].should eq "def"
  end

  it "blocks destructive work against a protected environment" do
    metadata = Grant::Schema::InternalMetadata.new(M03Fixture.adapter)
    metadata.record_environment("production")
    error = expect_raises(Grant::Schema::ProtectedEnvironmentError) { metadata.check_protected_environments!("production") }
    error.environment.should eq "production"
    expect_raises(Grant::Schema::ProtectedEnvironmentError) { metadata.check_protected_environments!("development") }
    metadata.check_protected_environments!("production", force: true)
    metadata.check_protected_environments!("production", protected_environments: ["prod"])
  end

  it "flags a database that belongs to another environment" do
    metadata = Grant::Schema::InternalMetadata.new(M03Fixture.adapter)
    metadata.record_environment("development")
    metadata.check_protected_environments!("development")
    expect_raises(Grant::Schema::EnvironmentMismatchError, /development/) { metadata.check_protected_environments!("test") }
  end

  it "protects a database with no recorded environment by the environment asked for" do
    metadata = Grant::Schema::InternalMetadata.new(M03Fixture.adapter)
    metadata.environment.should be_nil
    expect_raises(Grant::Schema::ProtectedEnvironmentError) { metadata.check_protected_environments!("production") }
    metadata.check_protected_environments!("development")
  end
end
