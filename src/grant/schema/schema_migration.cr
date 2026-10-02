require "../adapter/schema"

module Grant::Schema
  # The bookkeeping tables a migration runner keeps, created on demand.
  #
  # `Tracking::Grant` uses `schema_migrations(version)` like ActiveRecord.
  # `Tracking::Micrate` reads and writes the `micrate_db_version` table an
  # existing Micrate install already has, so the same database can move between
  # the two tools without replaying a single migration.
  enum Tracking
    Grant
    Micrate
  end

  # Applied-version bookkeeping for one database.
  #
  # Every call works on the adapter it was built with; under a schema-tenant
  # block that adapter's connection carries the `search_path`, so each tenant
  # keeps its own versions. `#versions` is a single `SELECT` of the whole
  # table; nothing here runs a query per migration file.
  class SchemaMigration
    TABLE         = "schema_migrations"
    MICRATE_TABLE = "micrate_db_version"

    getter adapter : Grant::Adapter::Base
    getter tracking : Tracking
    getter dialect : Dialect

    @table_present = false

    def initialize(@adapter : Grant::Adapter::Base, @tracking : Tracking = Tracking::Grant)
      @dialect = Dialect.for(@adapter)
    end

    def table_name : ::String
      @tracking.micrate? ? MICRATE_TABLE : TABLE
    end

    # True when the tracking table exists right now (asked of the catalog, not
    # of the schema cache, because another process may have created it).
    def table_exists? : Bool
      return true if @table_present
      found = @adapter.open do |db|
        case @dialect
        in .pg?     then db.scalar("SELECT to_regclass($1) IS NOT NULL", table_name).as(Bool)
        in .mysql?  then db.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", table_name).as(Int).to_i64 > 0
        in .sqlite? then db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", table_name).as(Int).to_i64 > 0
        end
      end
      @table_present = found
    end

    # Creates the tracking table unless it exists.
    def create_table : Nil
      return if table_exists?
      @adapter.open(&.exec(create_table_sql))
      @table_present = true
    end

    # Every applied version, from one `SELECT`. An absent table means none.
    def versions : Set(Int64)
      applied = Set(Int64).new
      return applied unless table_exists?
      if @tracking.micrate?
        # The newest row of a version decides; version 0 is Micrate's seed row.
        seen = Set(Int64).new
        sql = "SELECT version_id, is_applied FROM #{@dialect.quote(MICRATE_TABLE)} ORDER BY id DESC"
        @adapter.open(sql) do |db|
          db.query_each(sql) do |rs|
            version = rs.read(Int64)
            flag = rs.read
            next unless seen.add?(version)
            applied << version if version != 0 && truthy?(flag)
          end
        end
      else
        sql = "SELECT version FROM #{@dialect.quote(TABLE)}"
        @adapter.open(sql) do |db|
          db.query_each(sql) do |rs|
            if version = rs.read(::String).to_i64?
              applied << version
            end
          end
        end
      end
      applied
    end

    def current_version : Int64
      versions.max? || 0_i64
    end

    def applied?(version : Int64) : Bool
      versions.includes?(version)
    end

    # Marks *version* applied.
    def record(version : Int64) : Nil
      create_table
      if @tracking.micrate?
        @adapter.open { |db| db.exec "INSERT INTO #{@dialect.quote(MICRATE_TABLE)} (version_id, is_applied) VALUES (#{version}, #{@dialect.quote_literal(true)})" }
      else
        @adapter.open { |db| db.exec "INSERT INTO #{@dialect.quote(TABLE)} (version) VALUES ('#{version}')" }
      end
    end

    # Marks *version* not applied. Micrate's way is a new row with
    # `is_applied = false`, which keeps its history.
    def forget(version : Int64) : Nil
      return unless table_exists?
      if @tracking.micrate?
        @adapter.open { |db| db.exec "INSERT INTO #{@dialect.quote(MICRATE_TABLE)} (version_id, is_applied) VALUES (#{version}, #{@dialect.quote_literal(false)})" }
      else
        @adapter.open { |db| db.exec "DELETE FROM #{@dialect.quote(TABLE)} WHERE version = '#{version}'" }
      end
    end

    private def truthy?(flag) : Bool
      case flag
      when Bool then flag
      when Int  then flag != 0
      else           false
      end
    end

    private def create_table_sql : ::String
      if @tracking.micrate?
        case @dialect
        in .pg?     then "CREATE TABLE #{MICRATE_TABLE} (id serial NOT NULL, version_id bigint NOT NULL, is_applied boolean NOT NULL, tstamp timestamp NULL DEFAULT now(), PRIMARY KEY (id))"
        in .mysql?  then "CREATE TABLE #{MICRATE_TABLE} (id serial NOT NULL, version_id bigint NOT NULL, is_applied boolean NOT NULL, tstamp timestamp NULL DEFAULT now(), PRIMARY KEY (id))"
        in .sqlite? then "CREATE TABLE #{MICRATE_TABLE} (id INTEGER PRIMARY KEY AUTOINCREMENT, version_id INTEGER NOT NULL, is_applied INTEGER NOT NULL, tstamp TIMESTAMP DEFAULT (datetime('now')))"
        end
      else
        "CREATE TABLE #{TABLE} (version VARCHAR(255) NOT NULL PRIMARY KEY)"
      end
    end
  end
end
