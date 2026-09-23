require "../../spec_helper"

class SchemaTenantRecord < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table schema_tenant_records

  column id : Int64, primary: true
  column label : String
end

class SchemaTenantGlobalRecord < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table schema_tenant_global_records

  column id : Int64, primary: true
  column label : String

  schema_tenant_excluded
end

class SchemaTenantMigratedRecord < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table schema_tenant_migrated_records

  column id : Int64, primary: true
  column tenant_id : String
  column label : String
end

class SchemaTenantBlockError < Exception
end

{% if (env("CURRENT_ADAPTER") || "sqlite") == "pg" %}
  describe Grant::SchemaTenant do
    adapter = Grant::ConnectionRegistry.get_adapter("pg", :writing)
    schema_one = "grant_schema_tenant_one"
    schema_two = "grant_schema_tenant_two"
    schema_three = "grant_schema_tenant_three"

    before_all do
      # Earlier connection specs clear and rebuild the registry. Resolve the
      # current adapter after that reset instead of using the initial instance.
      adapter = Grant::ConnectionRegistry.get_adapter("pg", :writing)
      [schema_one, schema_two, schema_three].each do |schema|
        Grant::SchemaTenant.drop_schema(schema, adapter: adapter, cascade: true)
        Grant::SchemaTenant.create_schema(schema, adapter: adapter)
        Grant::SchemaTenant.create_tables(schema, SchemaTenantRecord)
      end

      SchemaTenantGlobalRecord.migrator.drop_and_create
      SchemaTenantMigratedRecord.migrator.drop_and_create
      adapter.open do |connection|
        connection.exec("CREATE SEQUENCE IF NOT EXISTS public.schema_tenant_migrated_records_id_seq")
      end
    end

    before_each do
      adapter = Grant::ConnectionRegistry.get_adapter("pg", :writing)
      [schema_one, schema_two, schema_three].each do |schema|
        Grant::SchemaTenant.with(schema, adapter: adapter) do
          SchemaTenantRecord.clear
        end
      end
      SchemaTenantGlobalRecord.clear
      SchemaTenantMigratedRecord.clear
    end

    after_all do
      adapter = Grant::ConnectionRegistry.get_adapter("pg", :writing)
      [schema_one, schema_two, schema_three].each do |schema|
        Grant::SchemaTenant.drop_schema(schema, adapter: adapter, cascade: true)
      end
      SchemaTenantGlobalRecord.migrator.drop
      SchemaTenantMigratedRecord.migrator.drop
      adapter.open do |connection|
        connection.exec("DROP SEQUENCE IF EXISTS public.schema_tenant_migrated_records_id_seq")
      end
    end

    it "isolates reads and CRUD operations in each schema" do
      Grant::SchemaTenant.with(schema_one, adapter: adapter) do
        Grant::SchemaTenant.current_schema.should eq(schema_one)
        SchemaTenantRecord.create!(id: 1_i64, label: "one")
        row = SchemaTenantRecord.find!(1_i64)
        row.label = "one updated"
        row.save!

        SchemaTenantRecord.where(id: 1_i64).select.map(&.label).should eq(["one updated"])
        row.destroy!
        SchemaTenantRecord.where(id: 1_i64).select.should be_empty
      end
      Grant::SchemaTenant.current_schema.should be_nil

      Grant::SchemaTenant.with(schema_two, adapter: adapter) do
        SchemaTenantRecord.create!(id: 1_i64, label: "two")
        SchemaTenantRecord.find!(1_i64).label.should eq("two")
      end
    end

    it "uses the pinned connection for committed and rolled-back transactions" do
      Grant::SchemaTenant.with(schema_one, adapter: adapter) do
        SchemaTenantRecord.transaction do
          SchemaTenantRecord.create!(id: 11_i64, label: "committed")
        end
        SchemaTenantRecord.find!(11_i64).label.should eq("committed")

        expect_raises(SchemaTenantBlockError) do
          SchemaTenantRecord.transaction do
            SchemaTenantRecord.create!(id: 12_i64, label: "rolled back")
            raise SchemaTenantBlockError.new("rollback")
          end
        end
        SchemaTenantRecord.where(id: 12_i64).select.should be_empty
      end
    end

    it "reuses and restores a transaction connection when the tenant block is inside a transaction" do
      SchemaTenantRecord.transaction do
        original_state = adapter.open do |connection|
          {
            connection.query_one("SELECT pg_backend_pid()", as: Int32),
            connection.query_one("SHOW search_path", as: String),
          }
        end

        Grant::SchemaTenant.with(schema_two, adapter: adapter) do
          SchemaTenantRecord.create!(id: 91_i64, label: "nested in transaction")
          adapter.open do |connection|
            connection.query_one("SELECT current_schema()", as: String).should eq(schema_two)
            connection.query_one("SELECT pg_backend_pid()", as: Int32).should eq(original_state[0])
          end
        end

        adapter.open do |connection|
          connection.query_one("SHOW search_path", as: String).should eq(original_state[1])
          connection.query_one("SELECT pg_backend_pid()", as: Int32).should eq(original_state[0])
        end
      end
    end

    it "restores the outer schema after a nested switch" do
      Grant::SchemaTenant.with(schema_one, adapter: adapter) do
        SchemaTenantRecord.create!(id: 21_i64, label: "outer")
        adapter.open { |connection| connection.query_one("SELECT current_schema()", as: String) }.should eq(schema_one)

        Grant::SchemaTenant.with(schema_two, adapter: adapter) do
          SchemaTenantRecord.create!(id: 21_i64, label: "inner")
          adapter.open { |connection| connection.query_one("SELECT current_schema()", as: String) }.should eq(schema_two)
        end

        adapter.open { |connection| connection.query_one("SELECT current_schema()", as: String) }.should eq(schema_one)
        SchemaTenantRecord.find!(21_i64).label.should eq("outer")
      end
    end

    it "resets search_path and clears the fiber context when the block raises" do
      original_search_path = adapter.open_pool_connection do |connection|
        connection.query_one("SHOW search_path", as: String)
      end

      expect_raises(SchemaTenantBlockError) do
        Grant::SchemaTenant.with(schema_one, adapter: adapter) do
          adapter.open { |connection| connection.query_one("SELECT current_schema()", as: String) }.should eq(schema_one)
          raise SchemaTenantBlockError.new("failed request")
        end
      end

      Grant::SchemaTenant.active?.should be_false
      adapter.open_pool_connection do |connection|
        connection.query_one("SHOW search_path", as: String).should eq(original_search_path)
      end
    end

    it "returns a checked-out connection with the original search_path" do
      original_search_path = adapter.open_pool_connection do |connection|
        connection.query_one("SHOW search_path", as: String)
      end

      Grant::SchemaTenant.with(schema_two, adapter: adapter) do
        adapter.open { |connection| connection.query_one("SHOW search_path", as: String) }
          .should contain(schema_two)
      end

      adapter.open_pool_connection do |connection|
        connection.query_one("SHOW search_path", as: String).should eq(original_search_path)
      end
    end

    it "keeps interleaved fibers isolated across three tenant schemas" do
      fibers = {
        {schema_one, "one"},
        {schema_two, "two"},
        {schema_three, "three"},
      }
      outcomes = Channel(Array(String)).new(fibers.size)

      fibers.each do |schema, label|
        spawn do
          failures = [] of String
          begin
            Grant::SchemaTenant.with(schema, adapter: adapter) do
              1.upto(16) do |iteration|
                id = iteration.to_i64
                SchemaTenantRecord.create!(id: id, label: label)
                Fiber.yield

                matching_rows = SchemaTenantRecord.where(id: id).select.map(&.label)
                failures << "#{schema} read #{matching_rows.inspect} at row #{id}" unless matching_rows == [label]
                all_rows = SchemaTenantRecord.all.to_a.map(&.label).uniq
                failures << "#{schema} saw #{all_rows.inspect}" unless all_rows == [label]
                Fiber.yield
              end
            end
          rescue ex
            failures << "#{schema} raised #{ex.class}: #{ex.message}"
          ensure
            outcomes.send(failures)
          end
        end
      end

      failures = fibers.size.times.flat_map { outcomes.receive }
      failures.should be_empty
    end

    it "queries and writes excluded models explicitly in public" do
      [schema_one, schema_two].each do |schema|
        SchemaTenantGlobalRecord.clear
        SchemaTenantGlobalRecord.create!(id: 1_i64, label: "public")
        adapter.open do |connection|
          connection.exec("CREATE TABLE IF NOT EXISTS #{adapter.quote(schema)}.#{adapter.quote("schema_tenant_global_records")} (id BIGINT PRIMARY KEY, label TEXT NOT NULL)")
          connection.exec("INSERT INTO #{adapter.quote(schema)}.#{adapter.quote("schema_tenant_global_records")} (id, label) VALUES (1, 'tenant') ON CONFLICT (id) DO UPDATE SET label = EXCLUDED.label")
        end

        Grant::SchemaTenant.with(schema, adapter: adapter) do
          row = SchemaTenantGlobalRecord.find!(1_i64)
          row.label.should eq("public")
          row.label = "public updated"
          row.save!
          SchemaTenantGlobalRecord.find!(1_i64).label.should eq("public updated")
        end
      end

      SchemaTenantGlobalRecord.schema_tenant_excluded?.should be_true
      SchemaTenantGlobalRecord.table_name.should eq("public.schema_tenant_global_records")
    end

    it "creates, lists, migrates, and drops tenant schemas" do
      schema = "grant_schema_tenant_lifecycle"
      Grant::SchemaTenant.drop_schema(schema, adapter: adapter, cascade: true)
      Grant::SchemaTenant.create_schema(schema, adapter: adapter)

      Grant::SchemaTenant.list_schemas(adapter: adapter).should contain(schema)
      Grant::SchemaTenant.create_tables(schema, SchemaTenantRecord)
      Grant::SchemaTenant.with(schema, adapter: adapter) do
        SchemaTenantRecord.create!(id: 31_i64, label: "created by lifecycle")
        SchemaTenantRecord.find!(31_i64).label.should eq("created by lifecycle")
      end

      Grant::SchemaTenant.drop_schema(schema, adapter: adapter, cascade: true)
      Grant::SchemaTenant.list_schemas(adapter: adapter).should_not contain(schema)
    ensure
      Grant::SchemaTenant.drop_schema("grant_schema_tenant_lifecycle", adapter: adapter, cascade: true)
    end

    it "renumbers colliding IDs while copying rows into a shared tenant table" do
      { {schema_one, "one", "first"}, {schema_two, "two", "second"} }.each do |schema, tenant_id, label|
        Grant::SchemaTenant.with(schema, adapter: adapter) do
          SchemaTenantRecord.create!(id: 1_i64, label: label)
        end
      end

      adapter.open do |connection|
        connection.exec(<<-SQL)
        CREATE TEMP TABLE schema_tenant_account_id_map (
          tenant_id text NOT NULL,
          old_id bigint NOT NULL,
          new_id bigint NOT NULL,
          PRIMARY KEY (tenant_id, old_id)
        )
        SQL

        begin
          { {schema_one, "one"}, {schema_two, "two"} }.each do |schema, tenant_id|
            source_table = adapter.quote("#{schema}.#{SchemaTenantRecord.table_name}")
            connection.exec(<<-SQL)
            INSERT INTO pg_temp.schema_tenant_account_id_map (tenant_id, old_id, new_id)
            SELECT '#{tenant_id}', source.id, nextval('public.schema_tenant_migrated_records_id_seq')
            FROM #{source_table} AS source
            SQL
          end

          { {schema_one, "one"}, {schema_two, "two"} }.each do |schema, tenant_id|
            source_table = adapter.quote("#{schema}.#{SchemaTenantRecord.table_name}")
            destination_table = adapter.quote(SchemaTenantMigratedRecord.table_name)
            connection.exec(<<-SQL)
            INSERT INTO #{destination_table} (id, tenant_id, label)
            SELECT id_map.new_id, id_map.tenant_id, source.label
            FROM #{source_table} AS source
            JOIN pg_temp.schema_tenant_account_id_map AS id_map
              ON id_map.tenant_id = '#{tenant_id}' AND id_map.old_id = source.id
            SQL
          end
        ensure
          connection.exec("DROP TABLE IF EXISTS pg_temp.schema_tenant_account_id_map")
        end
      end

      migrated_rows = SchemaTenantMigratedRecord.all.to_a
      migrated_rows.map { |row| {row.tenant_id, row.label} }.sort
        .should eq([{"one", "first"}, {"two", "second"}])
      migrated_rows.map(&.id).uniq.size.should eq(2)
    end

    it "rejects invalid and reserved schema names" do
      ["", "bad.name", "x; DROP SCHEMA public", "public", "pg_catalog", "a" * 64].each do |schema|
        expect_raises(Grant::InvalidSchemaNameError) do
          Grant::SchemaTenant.with(schema, adapter: adapter) { }
        end
      end
    end

    it "raises a clear error for non-PostgreSQL adapters" do
      sqlite_adapter = Grant::Adapter::Sqlite.new("schema_tenant_sqlite", "sqlite3::memory:")
      error = expect_raises(Grant::UnsupportedSchemaTenantAdapterError) do
        Grant::SchemaTenant.with("schema_tenant_sqlite", adapter: sqlite_adapter) { }
      end
      error.message.not_nil!.should contain("requires PostgreSQL")
    end

    it "rejects statements that resolve to a different adapter" do
      other_adapter = Grant::Adapter::Pg.new("schema_tenant_other", ADAPTER_URL)

      expect_raises(Grant::SchemaTenantConnectionMismatchError) do
        Grant::SchemaTenant.with(schema_one, adapter: adapter) do
          other_adapter.open { |_| }
        end
      end
    end
  end
{% else %}
  describe Grant::SchemaTenant do
    it "raises a clear error when the connection is not PostgreSQL" do
      adapter = Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER, :writing)
      error = expect_raises(Grant::UnsupportedSchemaTenantAdapterError) do
        Grant::SchemaTenant.with("schema_tenant_other", adapter: adapter) { }
      end
      error.message.not_nil!.should contain("requires PostgreSQL")
    end
  end
{% end %}
