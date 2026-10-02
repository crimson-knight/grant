require "../spec_helper"

module TestConnection
  def self.ensure_registered
    return if Grant::ConnectionRegistry.connection_exists?(CURRENT_ADAPTER, :primary)

    case CURRENT_ADAPTER
    when "pg"
      Grant::ConnectionRegistry.establish_connection(
        database: CURRENT_ADAPTER,
        adapter: Grant::Adapter::Pg,
        url: ADAPTER_URL
      )
    when "sqlite"
      Grant::ConnectionRegistry.establish_connection(
        database: CURRENT_ADAPTER,
        adapter: Grant::Adapter::Sqlite,
        url: ADAPTER_URL
      )
    when "mysql"
      Grant::ConnectionRegistry.establish_connection(
        database: CURRENT_ADAPTER,
        adapter: Grant::Adapter::Mysql,
        url: ADAPTER_URL
      )
    else
      raise "Unknown CURRENT_ADAPTER: #{CURRENT_ADAPTER}"
    end
  end
end
