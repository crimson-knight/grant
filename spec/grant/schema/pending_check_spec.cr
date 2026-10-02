require "../../support/m03_fixture"

describe "pending migration check" do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "reports pending migrations without creating any table" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, verbose: false)
    context.needs_migration?.should be_true
    M03Fixture.table?("schema_migrations").should be_false
    error = expect_raises(Grant::Schema::PendingMigrationError) { context.check_pending! }
    error.versions.should eq [20240101000001_i64, 20240101000002_i64]
    error.message.to_s.should contain "20240101000001, 20240101000002"
    expect_raises(Grant::Schema::PendingMigrationError) { Grant::Schema.check_pending!(context) }
  end

  it "is quiet once everything ran" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false)
    context.migrate
    context.needs_migration?.should be_false
    context.check_pending!
    Grant::Schema.check_pending!(context)
  end

  it "asks for one versions query per check" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, verbose: false)
    context.migrate
    queries = [] of String
    handler = ->(event : Grant::Events::SQL) { queries << event.sql; nil }
    Grant::Notifications.subscribed(Grant::Events::SQL, handler) { context.needs_migration?.should be_false }
    queries.count { |sql| sql.includes?("FROM \"schema_migrations\"") || sql.includes?("FROM `schema_migrations`") }.should eq 1
  end

  it "maintains the test schema: migrates by default, or loads the schema the caller gives" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false)
    Grant::Schema.maintain_test_schema!(context)
    M03Fixture.table?("m03_users").should be_true
    context.needs_migration?.should be_false

    M03Fixture.reset!
    loaded = false
    fresh = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false)
    expect_raises(Grant::Schema::PendingMigrationError) do
      Grant::Schema.maintain_test_schema!(fresh) { loaded = true }
    end
    loaded.should be_true
  end

  it "does nothing when the schema is current" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, verbose: false)
    context.migrate
    called = false
    Grant::Schema.maintain_test_schema!(context) { called = true }
    called.should be_false
  end
end
