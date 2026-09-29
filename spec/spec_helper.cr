require "mysql"
require "pg"
require "sqlite3"

# Enable test mode for HealthMonitor to prevent background fibers in tests
require "../src/grant"
Grant::HealthMonitor.test_mode = true

CURRENT_ADAPTER = ENV["CURRENT_ADAPTER"]? || "sqlite"
ADAPTER_URL     = ENV["#{CURRENT_ADAPTER.upcase}_DATABASE_URL"]? || if CURRENT_ADAPTER == "sqlite"
  "sqlite3:./grant_green.db"
else
  raise "Set #{CURRENT_ADAPTER.upcase}_DATABASE_URL to run the #{CURRENT_ADAPTER} specs"
end
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

{% if (env("CURRENT_ADAPTER") || "sqlite") == "mysql" && !flag?(:issue_473) %}
  Spec.after_each do
    # https://github.com/amberframework/grant/issues/473
    Grant::Connections["mysql"].not_nil![:writer].try &.database.pool.close
  end
{% end %}

# Several registry specs intentionally clear all connections. Restore the
# adapter-backed defaults after each example so later files do not resolve
# their default model connection through whichever fixture registered last.
private def restore_default_spec_connections
  adapter_type = case CURRENT_ADAPTER
                 when "pg"
                   Grant::Adapter::Pg
                 when "mysql"
                   Grant::Adapter::Mysql
                 else
                   Grant::Adapter::Sqlite
                 end

  unless Grant::ConnectionRegistry.connection_exists?(CURRENT_ADAPTER, :primary)
    Grant::ConnectionRegistry.establish_connection(
      database: CURRENT_ADAPTER,
      adapter: adapter_type,
      url: ADAPTER_URL,
      role: :primary
    )
  end

  replica_database = "#{CURRENT_ADAPTER}_with_replica"
  unless Grant::ConnectionRegistry.connection_exists?(replica_database, :writing)
    Grant::ConnectionRegistry.establish_connection(
      database: replica_database,
      adapter: adapter_type,
      url: ADAPTER_URL,
      role: :writing
    )
  end

  if ADAPTER_REPLICA_URL != ADAPTER_URL && !Grant::ConnectionRegistry.connection_exists?(replica_database, :reading)
    Grant::ConnectionRegistry.establish_connection(
      database: replica_database,
      adapter: adapter_type,
      url: ADAPTER_REPLICA_URL,
      role: :reading
    )
  end
end

private def restore_default_spec_runtime_state
  # Specs can change process-wide settings and fiber-local tenancy in addition
  # to clearing connections. Restore them before the next file's before_all.
  Grant.settings.default_timezone = Grant::TIME_ZONE
  Grant.settings.index_hint_mode = :warn
  Grant.settings.in_clause_limit = 1000
  Grant::Tenant.clear
  Grant::HealthMonitor.test_mode = true

  # Drop every class's contexts (connected_to leftovers and connecting_to that
  # a failed example never reset), not only those Grant::Base owns.
  Fiber.current.grant_connection_state = nil
  restore_default_spec_connections
  Grant::ConnectionRegistry.default_database = CURRENT_ADAPTER

  Log.builder.clear
  {% if flag?(:spec_logs) %}
    Log.builder.bind(
      source: "*",
      level: Log::Severity::Trace,
      backend: Log::IOBackend.new(STDOUT, dispatcher: :sync),
    )
  {% end %}
end

Spec.before_each do
  restore_default_spec_runtime_state
end

Spec.after_each do
  restore_default_spec_runtime_state
end
