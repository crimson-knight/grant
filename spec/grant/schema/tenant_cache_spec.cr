require "../../support/schema_fixture"

class M01TenantWidget < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m01_tenant_widgets

  column id : Int64, primary: true
  column label : String
end

class M01SharedWidget < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m01_shared_widgets

  column id : Int64, primary: true
  column label : String

  schema_tenant_excluded
end

{% if (env("CURRENT_ADAPTER") || "sqlite") == "pg" %}
  describe "Grant::Schema cache with schema tenants" do
    tenant_one = "m01_tenant_one"
    tenant_two = "m01_tenant_two"

    before_all do
      adapter = SchemaFixture.adapter
      [tenant_one, tenant_two].each do |tenant|
        Grant::SchemaTenant.drop_schema(tenant, adapter: adapter, cascade: true)
        Grant::SchemaTenant.create_schema(tenant, adapter: adapter)
      end
      Grant::SchemaTenant.create_tables(tenant_one, M01TenantWidget)
      M01SharedWidget.migrator.drop_and_create
    end

    after_all do
      adapter = SchemaFixture.adapter
      [tenant_one, tenant_two].each do |tenant|
        Grant::SchemaTenant.drop_schema(tenant, adapter: adapter, cascade: true)
      end
      M01SharedWidget.migrator.drop
    end

    it "keeps a separate cache per tenant schema" do
      adapter = SchemaFixture.adapter
      Grant::SchemaTenant.with(tenant_one, adapter: adapter) do
        M01TenantWidget.table_exists?.should be_true
        M01TenantWidget.column_exists?(:label).should be_true
      end
      Grant::SchemaTenant.with(tenant_two, adapter: adapter) do
        M01TenantWidget.table_exists?.should be_false
        M01TenantWidget.verify_schema.map(&.kind).should eq [Grant::Schema::Drift::Kind::MissingTable]
      end
      M01TenantWidget.table_exists?.should be_false
      adapter.schema(tenant_one).table_exists?(:m01_tenant_widgets).should be_true
    end

    it "reads public for a schema_tenant_excluded model, inside or outside a tenant" do
      M01SharedWidget.table_exists?.should be_true
      M01SharedWidget.verify_schema.should be_empty
      Grant::SchemaTenant.with(tenant_one, adapter: SchemaFixture.adapter) do
        M01SharedWidget.table_exists?.should be_true
        M01SharedWidget.database_columns.map(&.name).should eq ["id", "label"]
      end
    end

    it "resets every cached namespace when the migrator drops a table" do
      adapter = SchemaFixture.adapter
      adapter.schema("public").table_exists?(:m01_shared_widgets).should be_true
      M01SharedWidget.migrator.drop
      M01SharedWidget.table_exists?.should be_false
      adapter.schema("public").table_exists?(:m01_shared_widgets).should be_false
      M01SharedWidget.migrator.create
      M01SharedWidget.table_exists?.should be_true
    end

    it "forgets a tenant's cache when its schema is dropped" do
      adapter = SchemaFixture.adapter
      before = adapter.schema(tenant_two)
      Grant::SchemaTenant.drop_schema(tenant_two, adapter: adapter, cascade: true)
      adapter.schema(tenant_two).should_not be(before)
      Grant::SchemaTenant.create_schema(tenant_two, adapter: adapter)
    end
  end
{% else %}
  describe "Grant::Schema cache namespaces" do
    it "shares one cache for the connection outside schema tenancy" do
      adapter = SchemaFixture.adapter
      adapter.schema.should be(adapter.schema)
    end
  end
{% end %}
