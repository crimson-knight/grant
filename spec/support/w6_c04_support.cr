require "file_utils"
require "uri"

# Real databases for the connection and sharding specs of batch C04. Each spec
# names the databases it needs; the same example then runs on whichever adapter
# CURRENT_ADAPTER selects: one SQLite file per name, or one PostgreSQL database
# named `grant_w6_c04_<name>`. Rows are written and read through plain
# crystal-db connections, so what a Grant query returns names the database it
# actually reached.
module W6C04
  @@provisioned = [] of String

  def self.pg? : Bool
    CURRENT_ADAPTER == "pg"
  end

  def self.adapter_class : Grant::Adapter::Base.class
    pg? ? Grant::Adapter::Pg : Grant::Adapter::Sqlite
  end

  def self.dir : String
    path = File.join(Dir.tempdir, "w6_c04_#{Process.pid}")
    Dir.mkdir_p(path)
    path
  end

  def self.database_name(name : String) : String
    "grant_w6_c04_#{name}"
  end

  # A URL on the PostgreSQL server of `PG_DATABASE_URL`, naming *database*.
  def self.pg_url(database : String) : String
    uri = URI.parse(ADAPTER_URL)
    uri.path = "/#{database}"
    uri.query = nil
    uri.to_s
  end

  def self.url(name : String) : String
    pg? ? pg_url(database_name(name)) : "sqlite3:#{File.join(dir, "#{name}.sqlite3")}"
  end

  # Creates an empty database for *name* and returns its URL. Any earlier
  # database of that name is dropped first.
  def self.provision(name : String) : String
    drop(name)
    if pg?
      DB.open(pg_url("postgres")) { |db| db.exec "CREATE DATABASE #{database_name(name)}" }
    end
    @@provisioned << name
    url(name)
  end

  # Provisions *name* and runs *ddl* in it.
  def self.provision(name : String, ddl : Array(String)) : String
    database_url = provision(name)
    DB.open(database_url) { |db| ddl.each { |statement| db.exec statement } }
    database_url
  end

  def self.drop(name : String) : Nil
    if pg?
      DB.open(pg_url("postgres")) { |db| db.exec "DROP DATABASE IF EXISTS #{database_name(name)} WITH (FORCE)" }
    else
      File.delete?(File.join(dir, "#{name}.sqlite3"))
      %w[-wal -shm].each { |suffix| File.delete?(File.join(dir, "#{name}.sqlite3#{suffix}")) }
    end
  end

  # Drops every database `provision` created in this process.
  def self.cleanup : Nil
    @@provisioned.each { |name| drop(name) }
    @@provisioned.clear
    FileUtils.rm_rf(File.join(Dir.tempdir, "w6_c04_#{Process.pid}")) unless pg?
  end

  # Runs *sql* with *args* straight against the database *name*.
  def self.exec(name : String, sql : String, *args) : Nil
    params = [] of DB::Any
    args.each { |value| params << value }
    DB.open(url(name), &.exec(sql, args: params))
  end

  # The first column of every row of *sql* in the database *name*, as strings.
  def self.strings(name : String, sql : String) : Array(String)
    values = [] of String
    DB.open(url(name)) do |db|
      db.query(sql) { |rs| rs.each { values << rs.read(String) } }
    end
    values
  end

  # `$1`-style on PostgreSQL, `?` on SQLite.
  def self.placeholder(index : Int32 = 1) : String
    pg? ? "$#{index}" : "?"
  end

  # Establishes the connection *database* on the database *name*.
  def self.establish(database : String, name : String, role : Symbol = :writing, shard : Symbol? = nil, **options) : Grant::Adapter::Base
    Grant::ConnectionRegistry.establish_connection(
      **options, database: database, adapter: adapter_class, url: url(name),
      role: role, shard: shard, pool_size: 3, initial_pool_size: 1)
    Grant::ConnectionRegistry.get_adapter(database, role, shard)
  end

  # Removes the registry connections the example established.
  def self.remove(database : String, role : Symbol = :writing, shard : Symbol? = nil) : Nil
    if adapter = Grant::ConnectionRegistry.connection_exists?(database, role, shard) ? Grant::ConnectionRegistry.get_adapter(database, role, shard) : nil
      adapter.disconnect!
    end
    Grant::ConnectionRegistry.remove_connection(database, role, shard)
  end

  # The auto-increment id column definition of the adapter under test.
  def self.id_column : String
    pg? ? "id BIGSERIAL PRIMARY KEY" : "id INTEGER PRIMARY KEY AUTOINCREMENT"
  end
end
