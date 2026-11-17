require "db"

module Grant
end

require "./pg/*"

module Grant::PG
  # Establish a connection to the database
  def self.connect(url)
    DB.open(url)
  end

  # Establish a special listen-only connection to the database.
  #
  # ```
  # PG.connect_listen(ENV["DATABASE_URL"], "foo", "bar") do |notification|
  #   pp notification.channel, notification.payload, notification.pid
  # end
  # ```
  #
  # By default, this will spawn a fiber to non-blocking listen. If you would
  # rather handle this yourself, pass true to the blocking parameter.
  #
  # ```
  # PG.connect_listen("postgres:///", "a", "b", blocking: true) { ... }
  # ```

  def self.connect_listen(url, *channels : String, blocking : Bool = false, &blk : PQ::Notification ->) : ListenConnection
    connect_listen(url, channels, blocking, &blk)
  end

  # ditto
  def self.connect_listen(url, channels : Enumerable(String), blocking : Bool = false, &blk : PQ::Notification ->) : ListenConnection
    ListenConnection.new(url, channels, blocking, &blk)
  end

  def self.connect_replication(url, *, handler, publication_name, slot_name, keepalive_interval : Time::Span = 10.seconds)
    Replication::Connection.new(url, handler, publication_name: publication_name, slot_name: slot_name, keepalive_interval: keepalive_interval)
  end

  # The URL with a public PostgreSQL scheme (`postgres:` or `postgresql:`)
  # replaced by `Driver::GRANT_ONLY_SCHEME`, so the connection is built by Grant's
  # driver even when the app also requires the public `pg` shard, which
  # registers the public schemes too. Any other scheme is returned unchanged.
  def self.grant_only_url(url : String) : String
    url.sub(/\Apostgres(ql)?:/, "#{Driver::GRANT_ONLY_SCHEME}:")
  end

  # ditto
  def self.grant_only_url(uri : URI) : URI
    return uri unless uri.scheme.in?("postgres", "postgresql")

    grant_uri = uri.dup
    grant_uri.scheme = Driver::GRANT_ONLY_SCHEME
    grant_uri
  end

  # Opens one connection through Grant's driver (see `grant_only_url`). Raises
  # `Error` when the URL's scheme belongs to another driver, after closing the
  # connection that driver opened.
  def self.connect_with_grant_driver(url : String | URI) : Connection
    connection = DB.connect(grant_only_url(url))
    return connection if connection.is_a?(Connection)

    connection.close
    raise Error.new("#{connection.class} is not a Grant PostgreSQL connection; use a postgres://, postgresql:// or #{Driver::GRANT_ONLY_SCHEME}:// URL")
  end

  class ListenConnection
    @conn : PG::Connection

    def self.new(url, *channels : String, blocking : Bool = false, &blk : PQ::Notification ->)
      new(url, channels, blocking, &blk)
    end

    def initialize(url, channels : Enumerable(String), blocking : Bool = false, &blk : PQ::Notification ->)
      @conn = PG.connect_with_grant_driver(url)
      @conn.on_notification(&blk)

      @conn.listen(channels, blocking: blocking)
    end

    # Close the connection.
    def close
      @conn.close
    rescue
    end
  end
end
