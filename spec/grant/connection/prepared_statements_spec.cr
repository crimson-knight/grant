require "./pool_spec_support"

# Runs *count* distinct statements and reports how many prepared statements
# the (single) pooled connection is caching afterwards.
private def cached_statements_after(adapter : Grant::Adapter::Base, count : Int32) : Int32
  count.times { |i| adapter.open { |connection| connection.scalar("SELECT #{i + 1}") } }
  adapter.open { |connection| connection.statement_cache_size }
end

describe "prepared statements" do
  after_each do
    Grant::ConnectionRegistry.remove_connection("c02_prepared", :writing)
  end

  after_all { C02Support.cleanup }

  it "prepares and caches statements by default" do
    adapter = C02Support.establish("c02_prepared", pool_size: 1, initial_pool_size: 1)

    adapter.database.prepared_statements?.should be_true
    adapter.database.prepared_statements_cache?.should be_true
    cached_statements_after(adapter, 5).should be >= 5
  end

  it "keeps statement_limit as the most statements cached per connection" do
    adapter = C02Support.establish("c02_prepared", pool_size: 1, initial_pool_size: 1, statement_limit: 3)

    cached_statements_after(adapter, 12).should be <= 3

    # An evicted statement is simply prepared again.
    adapter.open { |connection| connection.scalar("SELECT 1") }.should eq 1
    adapter.open { |connection| connection.statement_cache_size }.should be <= 3
  end

  it "stops caching when statement_limit is 0" do
    adapter = C02Support.establish("c02_prepared", pool_size: 1, initial_pool_size: 1, statement_limit: 0)

    adapter.database.prepared_statements_cache?.should be_false
    cached_statements_after(adapter, 5).should eq 0
    adapter.open { |connection| connection.scalar("SELECT 41 + 1") }.should eq 42
  end

  it "turns preparing off for PgBouncer-style pooling where the driver supports it" do
    adapter = C02Support.establish("c02_prepared", pool_size: 1, initial_pool_size: 1, prepared_statements: false)

    if C02Support.adapter_class.supports_unprepared_statements?
      adapter.database.prepared_statements?.should be_false
      cached_statements_after(adapter, 5).should eq 0
    else
      # SQLite can only prepare, so the flag is ignored rather than breaking queries.
      adapter.database.prepared_statements?.should be_true
    end

    sql = adapter.ensure_clause_template("SELECT CAST(? AS BIGINT) + 1")
    adapter.open { |connection| connection.query_one(sql, 41, as: Int64) }.should eq 42
  end

  it "forwards the options as URL parameters only when they differ from the defaults" do
    defaults = Grant::ConnectionRegistry::ConnectionSpec.new("u", Grant::Adapter::Pg, "postgres://localhost/app", :writing)
    URI.parse(defaults.build_pool_url).query_params.has_key?("prepared_statements").should be_false
    URI.parse(defaults.build_pool_url).query_params.has_key?("prepared_statements_cache").should be_false

    tuned = Grant::ConnectionRegistry::ConnectionSpec.new(
      "u", Grant::Adapter::Pg, "postgres://localhost/app", :writing, prepared_statements: false, statement_limit: 0)
    params = URI.parse(tuned.build_pool_url).query_params
    params["prepared_statements"].should eq "false"
    params["prepared_statements_cache"].should eq "false"

    sqlite = Grant::ConnectionRegistry::ConnectionSpec.new(
      "u", Grant::Adapter::Sqlite, "sqlite3:./app.db", :writing, prepared_statements: false)
    URI.parse(sqlite.build_pool_url).query_params.has_key?("prepared_statements").should be_false
  end
end
