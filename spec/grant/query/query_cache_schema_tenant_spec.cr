require "../../spec_helper"

class QueryCacheQ05TenantNote < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table query_cache_q05_tenant_notes

  column id : Int64, primary: true
  column title : String
end

{% if (env("CURRENT_ADAPTER") || "sqlite") == "pg" %}
  describe "query cache with schema tenants" do
    q05_tenant_schemas = ["grant_q05_cache_tenant_one", "grant_q05_cache_tenant_two"]

    before_all do
      q05_tenant_adapter = QueryCacheQ05TenantNote.adapter
      q05_tenant_schemas.each do |schema|
        Grant::SchemaTenant.drop_schema(schema, adapter: q05_tenant_adapter, cascade: true)
        Grant::SchemaTenant.create_schema(schema, adapter: q05_tenant_adapter)
        Grant::SchemaTenant.create_tables(schema, QueryCacheQ05TenantNote)
      end
    end

    after_all do
      q05_tenant_adapter = QueryCacheQ05TenantNote.adapter
      q05_tenant_schemas.each do |schema|
        Grant::SchemaTenant.drop_schema(schema, adapter: q05_tenant_adapter, cascade: true)
      end
    end

    it "never answers one schema's read with another schema's rows" do
      Grant::SchemaTenant.with(q05_tenant_schemas[0]) do
        QueryCacheQ05TenantNote.create!(title: "first tenant")
      end

      Grant.cache do
        Grant::SchemaTenant.with(q05_tenant_schemas[0]) do
          QueryCacheQ05TenantNote.count.should eq 1
          # A nested block switches search_path on the same pinned connection.
          Grant::SchemaTenant.with(q05_tenant_schemas[1]) do
            QueryCacheQ05TenantNote.count.should eq 0
            QueryCacheQ05TenantNote.all.to_a.should be_empty
          end
          QueryCacheQ05TenantNote.all.to_a.map(&.title).should eq ["first tenant"]
        end
        # A later block may check the same connection out of the pool again.
        Grant::SchemaTenant.with(q05_tenant_schemas[1]) do
          QueryCacheQ05TenantNote.count.should eq 0
        end
      end
    end
  end
{% end %}
