require "../../spec_helper"

# Grant's drivers must stay out of the top level: an app that also loads the
# public pg or sqlite3 shard has to compile, and the adapter must keep Grant's
# own driver whichever shard registered the shared URI scheme last.
class OwnedNamespaceRefusingDriver < DB::Driver
  def connection_builder(uri : URI) : DB::ConnectionBuilder
    raise DB::Error.new("the public scheme was used")
  end
end

describe "Grant's owned database drivers" do
  it "leaves the public driver names free at the top level" do
    {{ @top_level.has_constant?("PG") }}.should be_false
    {{ @top_level.has_constant?("PQ") }}.should be_false
    {{ @top_level.has_constant?("SQLite3") }}.should be_false
    {{ @top_level.has_constant?("LibSQLite3") }}.should be_false
  end

  it "registers the URI schemes Grant apps use" do
    DB.driver_class("postgres").should eq Grant::PG::Driver
    DB.driver_class("postgresql").should eq Grant::PG::Driver
    DB.driver_class("sqlite3").should eq Grant::SQLite3::Driver
  end

  {% if (env("CURRENT_ADAPTER") || "sqlite") != "mysql" %}
    it "connects through its own scheme when another driver claims the public one" do
      public_scheme = CURRENT_ADAPTER == "pg" ? "postgres" : "sqlite3"
      owned_driver = CURRENT_ADAPTER == "pg" ? Grant::PG::Driver : Grant::SQLite3::Driver
      adapter_class = CURRENT_ADAPTER == "pg" ? Grant::Adapter::Pg : Grant::Adapter::Sqlite
      begin
        DB.register_driver public_scheme, OwnedNamespaceRefusingDriver
        adapter = adapter_class.new(name: "owned_namespace_check", url: ADAPTER_URL)
        adapter.open(&.scalar("SELECT 1")).should eq 1
        adapter.disconnect!
      ensure
        DB.register_driver public_scheme, owned_driver
      end
    end
  {% end %}
end
