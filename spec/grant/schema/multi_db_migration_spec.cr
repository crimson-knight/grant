require "../../support/m03_fixture"

class M03MultiA < Grant::Schema::Migration
  migration_version 20240601000001

  def change
    create_table :m03_a do |t|
      t.string :label
    end
  end
end

class M03MultiB < Grant::Schema::Migration
  migration_version 20240601000002

  def change
    create_table :m03_b do |t|
      t.string :label
    end
  end
end

class M03MultiFails < Grant::Schema::Migration
  migration_version 20240601000003

  def change
    create_table :m03_c do |t|
      t.string :label
    end
  end
end

class M03TenantItems < Grant::Schema::Migration
  migration_version 20240601000004

  def change
    create_table :m03_tenant_items do |t|
      t.string :label
    end
  end
end

describe "multi database migrations" do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "keeps versions per connection" do
    M03Fixture.with_second_adapter do |second|
      first_context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03MultiA, M03MultiB, verbose: false)
      second_context = Grant::Schema::MigrationContext.for(second, M03MultiA, verbose: false)
      first_context.migrate
      second_context.migrate
      M03Fixture.versions.should eq [20240601000001_i64, 20240601000002_i64]
      M03Fixture.versions(second).should eq [20240601000001_i64]
      M03Fixture.table?("m03_b").should be_true
      M03Fixture.table?("m03_b", second).should be_false
      second_context.current_version.should eq 20240601000001_i64
    end
  end

  it "migrates every target and reports each target's versions" do
    M03Fixture.with_second_adapter do |second|
      migrator = Grant::Schema::MultiDatabaseMigrator.new({
        "primary"   => Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03MultiA, M03MultiB, verbose: false),
        "secondary" => Grant::Schema::MigrationContext.for(second, M03MultiA, M03MultiB, verbose: false),
      })
      migrator.skew.skewed?.should be_false
      report = migrator.migrate(parallelism: 2)
      report.succeeded?.should be_true
      report.results.map(&.label).should eq ["primary", "secondary"]
      report.results.map(&.ran).should eq [[20240601000001_i64, 20240601000002_i64]] * 2
      migrator.versions.should eq({"primary" => 20240601000002_i64, "secondary" => 20240601000002_i64})
      migrator.skew.skewed?.should be_false

      migrator.rollback.succeeded?.should be_true
      migrator.versions.values.should eq [20240601000001_i64, 20240601000001_i64]
    end
  end

  it "reports a failed shard and the skew it leaves instead of hiding it" do
    M03Fixture.with_second_adapter do |second|
      migrator = Grant::Schema::MultiDatabaseMigrator.new({
        "healthy" => Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03MultiA, M03MultiFails, verbose: false),
        "broken"  => Grant::Schema::MigrationContext.for(second, M03MultiA, M03MultiFails, verbose: false),
      })
      # Break one shard only: its table cannot be created because a view by that name is in the way.
      second.open { |db| db.exec "CREATE VIEW m03_c AS SELECT 1 AS id" }
      report = migrator.migrate(parallelism: 2)
      report.succeeded?.should be_false
      report.failed.map(&.label).should eq ["broken"]
      report.results.find!(&.label.== "healthy").failed?.should be_false
      migrator.versions.should eq({"healthy" => 20240601000003_i64, "broken" => 20240601000001_i64})
      migrator.skew.skewed?.should be_true
      migrator.skew.behind.should eq ["broken"]
      error = expect_raises(Grant::Schema::MigrationFailed) { report.raise_if_failed! }
      error.failures.keys.should eq ["broken"]
    end
  end

  it "runs migrations on a named connection from the registry" do
    M03Fixture.with_second_adapter do |second|
      Grant::ConnectionRegistry.establish_connection("m03_named", second.url)
      begin
        entries = [M03MultiA.entry, M03MultiB.entry]
        migrator = Grant::Schema::MultiDatabaseMigrator.for_connections({"m03_named" => entries}, verbose: false)
        migrator.migrate.succeeded?.should be_true
        M03Fixture.table?("m03_b", second).should be_true
        M03Fixture.versions(second).should eq [20240601000001_i64, 20240601000002_i64]
        M03Fixture.table?("m03_b").should be_false
      ensure
        Grant::ConnectionRegistry.remove_connection("m03_named", :primary)
      end
    end
  end

  it "migrates each configured shard of a database on its own" do
    M03Fixture.with_second_adapter do |shard_one|
      M03Fixture.with_second_adapter do |shard_two|
        Grant::ConnectionRegistry.establish_connection("m03_sharded", shard_one.url, :primary, :one)
        Grant::ConnectionRegistry.establish_connection("m03_sharded", shard_two.url, :primary, :two)
        begin
          migrator = Grant::Schema::MultiDatabaseMigrator.for_shards("m03_sharded", [:one, :two], migrations: [M03MultiA.entry], verbose: false)
          migrator.targets.keys.should eq ["m03_sharded:one", "m03_sharded:two"]
          migrator.migrate(parallelism: 2).succeeded?.should be_true
          M03Fixture.table?("m03_a", shard_one).should be_true
          M03Fixture.table?("m03_a", shard_two).should be_true
          migrator.skew.skewed?.should be_false
        ensure
          Grant::ConnectionRegistry.remove_connection("m03_sharded", :primary, :one)
          Grant::ConnectionRegistry.remove_connection("m03_sharded", :primary, :two)
        end
      end
    end
  end

  if CURRENT_ADAPTER == "pg"
    it "migrates every PostgreSQL schema tenant with its own schema_migrations" do
      adapter = M03Fixture.adapter
      schemas = ["m03_t1", "m03_t2"]
      schemas.each do |schema|
        adapter.open { |db| db.exec "DROP SCHEMA IF EXISTS #{schema} CASCADE" }
        Grant::SchemaTenant.create_schema(schema, adapter)
      end
      begin
        migrator = Grant::Schema::MultiDatabaseMigrator.for_tenants(adapter, schemas, migrations: [M03TenantItems.entry], verbose: false)
        migrator.migrate(parallelism: 2).succeeded?.should be_true
        schemas.each do |schema|
          tables = adapter.open { |db| db.query_all("SELECT table_name FROM information_schema.tables WHERE table_schema = '#{schema}' ORDER BY 1", as: String) }
          tables.should eq ["m03_tenant_items", "schema_migrations"]
        end
        migrator.versions.should eq({"m03_t1" => 20240601000004_i64, "m03_t2" => 20240601000004_i64})
        M03Fixture.table?("m03_tenant_items").should be_false
      ensure
        schemas.each { |schema| adapter.open { |db| db.exec "DROP SCHEMA IF EXISTS #{schema} CASCADE" } }
      end
    end
  end
end
