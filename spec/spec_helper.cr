require "mysql"
require "pg"
require "sqlite3"

# Enable test mode for HealthMonitor to prevent background fibers in tests
require "../src/grant"
Grant::HealthMonitor.test_mode = true

CURRENT_ADAPTER     = ENV["CURRENT_ADAPTER"]
ADAPTER_URL         = ENV["#{CURRENT_ADAPTER.upcase}_DATABASE_URL"]
ADAPTER_REPLICA_URL = ENV["#{CURRENT_ADAPTER.upcase}_REPLICA_URL"]? || ADAPTER_URL

case CURRENT_ADAPTER
when "pg"
  Grant::Connections << Grant::Adapter::Pg.new(name: CURRENT_ADAPTER, url: ADAPTER_URL)
  Grant::Connections << {name: "pg_with_replica", writer: ADAPTER_URL, reader: ADAPTER_REPLICA_URL, adapter_type: Grant::Adapter::Pg}
when "mysql"
  Grant::Connections << Grant::Adapter::Mysql.new(name: CURRENT_ADAPTER, url: ADAPTER_URL)
  Grant::Connections << {name: "mysql_with_replica", writer: ADAPTER_URL, reader: ADAPTER_REPLICA_URL, adapter_type: Grant::Adapter::Mysql}
when "sqlite"
  Grant::Connections << Grant::Adapter::Sqlite.new(name: CURRENT_ADAPTER, url: ADAPTER_URL)
  Grant::Connections << {name: "sqlite_with_replica", writer: ADAPTER_URL, reader: ADAPTER_REPLICA_URL, adapter_type: Grant::Adapter::Sqlite}
when Nil
  raise "Please set CURRENT_ADAPTER"
else
  raise "Unknown adapter #{CURRENT_ADAPTER}"
end

require "spec"
require "../src/grant"
require "../src/adapter/**"
require "./spec_models"
require "./mocks/**"

Spec.before_suite do
  Grant.settings.default_timezone = Grant::TIME_ZONE
  {% if flag?(:spec_logs) %}
    ::Log.builder.bind(
      # source: "spec.client",
      source: "*",
      level: ::Log::Severity::Trace,
      backend: ::Log::IOBackend.new(STDOUT, dispatcher: :sync),
    )
  {% end %}
end

Spec.before_each do
  # I have no idea why this is needed, but it is.
  Grant.settings.default_timezone = Grant::TIME_ZONE
end

{% if env("CURRENT_ADAPTER") == "mysql" && !flag?(:issue_473) %}
  Spec.after_each do
    # https://github.com/amberframework/grant/issues/473
    Grant::Connections["mysql"].not_nil![:writer].try &.database.pool.close
  end
{% end %}
