class Grant::PG::Driver < ::DB::Driver
  # A scheme only this driver registers. `Grant::Adapter::Pg` connects through it,
  # so the connection keeps this driver when the app also requires the public
  # `pg` shard, which registers `postgres` and `postgresql` too.
  GRANT_ONLY_SCHEME = "grant-postgres"

  class ConnectionBuilder < ::DB::ConnectionBuilder
    def initialize(@options : ::DB::Connection::Options, @conn_info : PQ::ConnInfo)
    end

    def build : ::DB::Connection
      PG::Connection.new(@options, @conn_info)
    end
  end

  def connection_builder(uri : URI) : ::DB::ConnectionBuilder
    params = HTTP::Params.parse(uri.query || "")
    ConnectionBuilder.new(connection_options(params), PQ::ConnInfo.new(uri))
  end
end

DB.register_driver "postgres", Grant::PG::Driver
DB.register_driver "postgresql", Grant::PG::Driver
DB.register_driver Grant::PG::Driver::GRANT_ONLY_SCHEME, Grant::PG::Driver
