require "file_utils"
require "../spec_helper"
require "../../src/grant/sharding"

module Grant::Testing
  # Real shards for sharding specs: one SQLite file per shard, registered in the
  # connection registry under one database name, so a query that names a shard
  # reads and writes that shard's file and no other.
  #
  # ```
  # fixture = Grant::Testing::RealSqliteShards.new("my_db", [:one, :two],
  #   ["CREATE TABLE things (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL)"])
  # fixture.set_up
  # # ... exercise models declared with `connection "my_db"` ...
  # fixture.tear_down
  # ```
  #
  # With `readers: true` each shard also gets a second file registered as its
  # `:reading` connection. The schema is applied to both, and rows are not
  # replicated, so what a read returns names the file it came from.
  #
  # The fixture only removes the connections it registered, so the default spec
  # connections survive `tear_down`.
  class RealSqliteShards
    getter database : String
    getter shards : Array(Symbol)
    getter directory : String

    def initialize(@database : String, @shards : Array(Symbol), @ddl : Array(String), @readers : Bool = false)
      @directory = File.join(Dir.tempdir, "#{@database}_#{Process.pid}_#{Random::Secure.hex(4)}")
    end

    # The file behind *shard*'s writing connection, or its reader with `reader: true`.
    def path_for(shard : Symbol, reader : Bool = false) : String
      File.join(@directory, reader ? "#{shard}_reader.sqlite3" : "#{shard}.sqlite3")
    end

    # Creates the files and registers a connection per file. Each shard is
    # registered as `:primary` (the role a model uses outside `connected_to`),
    # and its reader as `:reading`.
    def set_up : Nil
      Dir.mkdir_p(@directory)
      @shards.each do |shard|
        create_file(path_for(shard))
        register(shard, path_for(shard), :primary)
        if @readers
          create_file(path_for(shard, reader: true))
          register(shard, path_for(shard, reader: true), :reading)
        end
      end
    end

    # Closes every pool this fixture opened, removes its connections and deletes its files.
    def tear_down : Nil
      @shards.each do |shard|
        {:primary, :reading}.each do |role|
          next unless Grant::ConnectionRegistry.connection_exists?(@database, role, shard)
          if adapter = Grant::ConnectionRegistry.get_adapter(@database, role, shard).as?(Grant::Adapter::Sqlite)
            adapter.database.pool.close
          end
          Grant::ConnectionRegistry.remove_connection(@database, role, shard)
        end
      end
      FileUtils.rm_rf(@directory)
    end

    # Runs *sql* directly against *shard*'s file, bypassing Grant's routing.
    def exec(shard : Symbol, sql : String, *args, reader : Bool = false) : Nil
      DB.open("sqlite3:#{path_for(shard, reader)}") { |db| db.exec(sql, args: args.to_a) }
    end

    # Reads one Int64 column directly from *shard*'s file, bypassing Grant's routing.
    def int_values(shard : Symbol, sql : String, reader : Bool = false) : Array(Int64)
      values = [] of Int64
      DB.open("sqlite3:#{path_for(shard, reader)}") do |db|
        db.query(sql) { |rs| rs.each { values << rs.read(Int64) } }
      end
      values
    end

    private def create_file(path : String) : Nil
      File.delete?(path)
      DB.open("sqlite3:#{path}") { |db| @ddl.each { |statement| db.exec(statement) } }
    end

    private def register(shard : Symbol, path : String, role : Symbol) : Nil
      Grant::ConnectionRegistry.establish_connection(
        database: @database,
        adapter: Grant::Adapter::Sqlite,
        url: "sqlite3:#{path}",
        role: role,
        shard: shard,
        pool_size: 2,
        initial_pool_size: 1
      )
    end
  end
end
