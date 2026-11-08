class Grant::SQLite3::Driver < DB::Driver
  # A scheme only this driver registers. `Grant::Adapter::Sqlite` connects through
  # it, so the connection keeps this driver when the app also requires the public
  # `sqlite3` shard, which registers `sqlite3` too.
  GRANT_ONLY_SCHEME = "grant-sqlite3"

  class ConnectionBuilder < ::DB::ConnectionBuilder
    def initialize(@options : ::DB::Connection::Options, @sqlite3_options : SQLite3::Connection::Options)
    end

    def build : ::DB::Connection
      SQLite3::Connection.new(@options, @sqlite3_options)
    end
  end

  def connection_builder(uri : URI) : ::DB::ConnectionBuilder
    params = HTTP::Params.parse(uri.query || "")
    ConnectionBuilder.new(connection_options(params), SQLite3::Connection::Options.from_uri(uri))
  end
end

DB.register_driver "sqlite3", Grant::SQLite3::Driver
DB.register_driver Grant::SQLite3::Driver::GRANT_ONLY_SCHEME, Grant::SQLite3::Driver
