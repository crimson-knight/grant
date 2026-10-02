require "uri"
require "file_utils"
require "../schema/loader"
require "../seeds"
require "../database_configurations"

module Grant
  module Tasks
    # Raised when a database task cannot run, for example the target database
    # does not exist or the adapter has no task support.
    class DatabaseTaskError < Grant::ErrorBase
    end

    # Programmatic database tasks: what `rails db:create`, `db:drop`,
    # `db:migrate`, `db:schema:dump`, `db:setup`, `db:reset`, `db:prepare`,
    # `db:seed` and `db:truncate_all` do. The Amber CLI is a thin wrapper
    # around this class.
    #
    # ```
    # tasks = Grant::Tasks::Database.for_connection("development", "primary",
    #   migrations: Grant::Schema::Migration.registry)
    # tasks.prepare # create, load the schema, seed (new database) or migrate
    # tasks.migrate
    # tasks.schema_dump        # writes db/schema.cr (or db/structure.sql)
    # tasks.drop(force: false) # refuses a protected environment
    # ```
    #
    # Destructive tasks (`drop`, `purge`, `reset`, `schema_load` on an existing
    # database, `truncate_all`) call `guard!`: they raise
    # `Grant::Schema::ProtectedEnvironmentError` when the environment is in
    # `protected_environments` (`["production"]` by default), or when the
    # database was recorded as a protected environment, unless `force: true`.
    #
    # Creating and dropping databases connects to the server's maintenance
    # database (`postgres`, or no database on MySQL), not through the pool, so
    # the target can be absent. SQLite databases are files: create makes the
    # file, drop deletes it (and its WAL and SHM files).
    class Database
      getter name : ::String
      getter url : ::String
      getter environment : ::String
      getter protected_environments : Array(::String)
      getter migration_paths : Array(::String)
      getter seed_path : ::String
      getter db_dir : ::String
      getter schema_format : Schema::SchemaFormat
      getter tracking : Schema::Tracking
      # False for a database configured with `database_tasks: false`: the
      # create, drop, migrate, schema, seed and combined tasks do nothing for
      # it, as `rails db:*` skips such a database.
      getter? database_tasks : Bool

      @migrations : Array(Schema::MigrationEntry)?
      @adapter : Grant::Adapter::Base?
      @output : IO?

      # *migrations* defaults to every registered migration class.
      def initialize(@url : ::String, @environment : ::String, @name : ::String = "primary",
                     adapter : Grant::Adapter::Base? = nil, @migrations : Array(Schema::MigrationEntry)? = nil,
                     @migration_paths : Array(::String) = [] of ::String, @seed_path : ::String = Seeds::DEFAULT_PATH,
                     @db_dir : ::String = "db", @schema_format : Schema::SchemaFormat = Schema.format,
                     @protected_environments : Array(::String) = Schema::InternalMetadata::DEFAULT_PROTECTED,
                     @tracking : Schema::Tracking = Schema::Tracking::Grant, @output : IO? = nil,
                     @database_tasks : Bool = true)
        @adapter = adapter
      end

      # The tasks of the registered connection *database*, run on its adapter,
      # so models keep working after a drop and create.
      def self.for_connection(environment : ::String, database : ::String = Grant::Base.default_database_name, **options) : Database
        adapter = Grant::ConnectionRegistry.get_adapter(database)
        new(adapter.url, environment, database, **options.merge(adapter: adapter))
      end

      # The tasks of one entry of a `Grant::DatabaseConfigurations`.
      def self.for_config(config : Grant::DatabaseConfig, **options) : Database
        new(config.url, config.env, config.name, **options, database_tasks: config.database_tasks?)
      end

      # The tasks of every database *configurations* lists for its environment,
      # leaving out replicas and databases with `database_tasks: false`.
      def self.for_configurations(configurations : Grant::DatabaseConfigurations, **options) : Array(Database)
        configurations.task_configs.map { |config| for_config(config, **options) }
      end

      # The adapter of the target database, opened on first use.
      def adapter : Grant::Adapter::Base
        @adapter ||= build_adapter
      end

      def dialect : Schema::Dialect
        Schema::Dialect.for(adapter)
      end

      # `db/schema.cr` or `db/structure.sql`, by `schema_format`; other databases
      # than `primary` get a `<name>_` prefix.
      def schema_path : ::String
        File.join(@db_dir, @schema_format.file_name(@name))
      end

      # ---- create, drop, purge -------------------------------------------

      # True when the database exists on its server (or its file exists).
      def exists? : Bool
        case adapter_kind
        in .sqlite?
          path = sqlite_path
          path == ":memory:" || File.exists?(path)
        in .pg?
          with_maintenance_connection do |db|
            db.scalar("SELECT COUNT(*) FROM pg_database WHERE datname = $1", database_name).as(Int).to_i64 > 0
          end
        in .mysql?
          with_maintenance_connection do |db|
            db.scalar("SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = ?", database_name).as(Int).to_i64 > 0
          end
        end
      end

      # Creates the database. Returns false, changing nothing, when it already
      # exists. PostgreSQL takes an `encoding:` and a `template:`; MySQL a
      # `charset:` and `collation:` (default `utf8mb4`).
      def create(encoding : ::String? = nil, template : ::String? = nil, charset : ::String? = nil,
                 collation : ::String? = nil) : Bool
        return false unless database_tasks?
        return false if exists?
        case adapter_kind
        in .sqlite?
          path = sqlite_path
          FileUtils.mkdir_p(File.dirname(path))
          File.touch(path)
        in .pg?
          sql = "CREATE DATABASE #{quote(database_name)}"
          sql += " ENCODING #{literal(encoding)}" if encoding
          sql += " TEMPLATE #{quote(template)}" if template
          with_maintenance_connection(&.exec(sql))
        in .mysql?
          sql = "CREATE DATABASE #{quote(database_name)} CHARACTER SET #{charset || "utf8mb4"}"
          sql += " COLLATE #{collation}" if collation
          with_maintenance_connection(&.exec(sql))
        end
        true
      end

      # Drops the database. Returns false when it did not exist. Raises
      # `Grant::Schema::ProtectedEnvironmentError` in a protected environment
      # unless *force*.
      def drop(force : Bool = false) : Bool
        return false unless database_tasks?
        guard!(force)
        drop_database
      end

      # Empties the database by dropping and recreating it (SQLite: deleting
      # and recreating the file; an in-memory database loses its tables).
      # Guarded like `drop`.
      def purge(force : Bool = false) : Nil
        return unless database_tasks?
        guard!(force)
        if sqlite? && sqlite_path == ":memory:"
          drop_all_tables
          return
        end
        drop_database
        create
      end

      # ---- migrations ----------------------------------------------------

      # The migration context over this database.
      def migration_context : Schema::MigrationContext
        entries = @migrations || Schema::Migration.registry.dup
        Schema::MigrationContext.new(adapter, entries, paths: @migration_paths, tracking: @tracking,
          output: @output, environment: @environment)
      end

      # Runs the pending migrations (or goes to *target*), then dumps the schema
      # file in every environment but production-like ones: pass `dump: false`
      # to skip. Returns the versions that ran.
      def migrate(target : Int64? = nil, dump : Bool = false) : Array(Int64)
        return [] of Int64 unless database_tasks?
        ran = migration_context.migrate(target)
        schema_dump if dump && !ran.empty?
        ran
      end

      def rollback(step : Int32 = 1, dump : Bool = false) : Array(Int64)
        return [] of Int64 unless database_tasks?
        ran = migration_context.rollback(step)
        schema_dump if dump && !ran.empty?
        ran
      end

      def status : Array(Schema::MigrationStatus)
        migration_context.status
      end

      # The newest applied migration version, 0 when none.
      def version : Int64
        Schema::SchemaMigration.new(adapter, @tracking).current_version
      end

      # ---- schema dump and load ------------------------------------------

      # Writes the schema file for `schema_format` to *path* and returns the path.
      def schema_dump(path : ::String = schema_path) : ::String
        return path unless database_tasks?
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "w") do |file|
          if @schema_format.sql?
            Schema::Dumper.dump_structure(adapter, file, @tracking)
          else
            Schema::Dumper.dump(adapter, file, tracking: @tracking)
          end
        end
        path
      end

      # Writes the SQL structure file (whatever `schema_format` is).
      def structure_dump(path : ::String = File.join(@db_dir, Schema::SchemaFormat::Sql.file_name(@name))) : ::String
        return path unless database_tasks?
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "w") { |file| Schema::Dumper.dump_structure(adapter, file, @tracking) }
        path
      end

      # Loads the schema file into the database, which must exist. A Crystal
      # schema replaces its tables (`force: :cascade`); a structure file must
      # go into an empty database (`purge` first). Migration versions the
      # registered migrations hold up to the schema's version are recorded as
      # applied. Guarded unless *force* or the database is empty.
      def schema_load(path : ::String = schema_path, force : Bool = false) : Int64
        return 0_i64 unless database_tasks?
        raise Schema::SchemaFileMissing.new(path) unless File.exists?(path) || Schema.definition_for(path)
        loader = Schema::Loader.new(adapter, @environment, @protected_environments, @tracking, known_versions, force)
        loader.load(path)
      end

      # ---- seeds ----------------------------------------------------------

      # Runs the seeds file registered for `seed_path`. Returns how many
      # `Seeds.define` blocks ran.
      def seed(path : ::String = @seed_path) : Int32
        return 0 unless database_tasks?
        Seeds.run(path, adapter)
      end

      # ---- combined tasks -------------------------------------------------

      # Creates the database, loads the schema and seeds it (`db:setup`).
      def setup(seed : Bool = true) : Nil
        return unless database_tasks?
        created = create
        schema_load(force: created)
        self.seed if seed
      end

      # Drops and sets the database up again (`db:reset`). Guarded like `drop`.
      def reset(force : Bool = false, seed : Bool = true) : Nil
        return unless database_tasks?
        drop(force)
        setup(seed)
      end

      # Gets the database ready (`db:prepare`): an existing database is
      # migrated; a new one is created, loaded from the schema file (or migrated
      # when there is none) and seeded.
      def prepare(seed : Bool = true) : Nil
        return unless database_tasks?
        if exists?
          migrate
        else
          create
          if File.exists?(schema_path) || Schema.definition_for(schema_path)
            schema_load(force: true)
          else
            migrate
          end
          self.seed if seed && Seeds.defined?(@seed_path)
        end
      end

      # ---- data -----------------------------------------------------------

      # Empties every table but the migration bookkeeping in one statement
      # (`TRUNCATE ... RESTART IDENTITY CASCADE` on PostgreSQL), restarting id
      # counters. *except* tables are kept. Returns the tables emptied.
      # Guarded like `drop`.
      def truncate_all(except : Array(::String) = [] of ::String, force : Bool = false) : Array(::String)
        return [] of ::String unless database_tasks?
        guard!(force)
        keep = [Schema::SchemaMigration::TABLE, Schema::SchemaMigration::MICRATE_TABLE, Schema::InternalMetadata::TABLE]
        adapter.schema.reset!
        tables = adapter.schema.tables.reject { |table| keep.includes?(table) || except.includes?(table) }
        adapter.truncate_tables(tables)
        tables
      end

      # ---- guard ----------------------------------------------------------

      # Raises `Grant::Schema::ProtectedEnvironmentError` when this environment
      # is protected, or `EnvironmentMismatchError` when the database belongs
      # to another one, unless *force*.
      def guard!(force : Bool = false) : Nil
        return if force
        raise Schema::ProtectedEnvironmentError.new(@environment) if @protected_environments.includes?(@environment)
        return unless exists?
        Schema::InternalMetadata.new(adapter).check_protected_environments!(@environment, @protected_environments, false)
      end

      # ---- internals ------------------------------------------------------

      private def known_versions : Array(Int64)
        migration_context.migrations.map(&.version)
      end

      private def drop_database : Bool
        return false unless exists?
        @adapter.try(&.disconnect!)
        case adapter_kind
        in .sqlite?
          path = sqlite_path
          if path == ":memory:"
            drop_all_tables
          else
            {"", "-wal", "-shm", "-journal"}.each { |suffix| File.delete?(path + suffix) }
          end
        in .pg?
          with_maintenance_connection do |db|
            db.exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()", database_name
            db.exec "DROP DATABASE IF EXISTS #{quote(database_name)}"
          end
        in .mysql?
          with_maintenance_connection { |db| db.exec "DROP DATABASE IF EXISTS #{quote(database_name)}" }
        end
        true
      end

      # Drops every table: a database that cannot be deleted.
      private def drop_all_tables : Nil
        adapter.schema.reset!
        tables = adapter.schema.tables
        return if tables.empty?
        statements = Schema::AdapterStatements.new(adapter)
        tables.each { |table| statements.drop_table(table, if_exists: true) }
        adapter.reset_schema_caches!
      end

      private def sqlite? : Bool
        adapter_kind.sqlite?
      end

      private enum Kind
        Sqlite
        Pg
        Mysql
      end

      private def adapter_kind : Kind
        scheme = Grant::Adapter::Registry.scheme_of(@url) || raise DatabaseTaskError.new("#{Grant::Adapter::Registry.redact(@url)} has no URL scheme")
        case scheme.downcase
        when "sqlite3", "sqlite"            then Kind::Sqlite
        when "postgres", "postgresql", "pg" then Kind::Pg
        when "mysql"                        then Kind::Mysql
        else                                     raise DatabaseTaskError.new("Database tasks do not support the #{scheme} adapter")
        end
      end

      private def build_adapter : Grant::Adapter::Base
        Grant::Adapter::Registry.for_url(@url).new(name: @name, url: @url)
      end

      private def sqlite_path : ::String
        uri = URI.parse(@url)
        URI.decode_www_form((uri.hostname || "") + uri.path)
      end

      private def database_name : ::String
        URI.decode_www_form(URI.parse(@url).path.lstrip('/'))
      end

      # A short-lived connection to the server's maintenance database.
      private def with_maintenance_connection(& : DB::Connection -> T) : T forall T
        uri = URI.parse(@url)
        uri.path = adapter_kind.pg? ? "/postgres" : "/"
        uri.query = nil
        DB.open(uri.to_s) { |db| db.using_connection { |connection| yield connection } }
      end

      private def quote(name : ::String) : ::String
        adapter_kind.mysql? ? "`#{name.gsub('`', "``")}`" : "\"#{name.gsub('"', "\"\"")}\""
      end

      private def literal(value : ::String) : ::String
        "'#{value.gsub("'", "''")}'"
      end
    end
  end
end
