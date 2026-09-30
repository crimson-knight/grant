require "./dumper"
require "./migration_context"

module Grant::Schema
  # Raised when a schema file to load does not exist.
  class SchemaFileMissing < Grant::ErrorBase
    getter path : ::String

    def initialize(@path : ::String)
      super("Schema file #{@path} does not exist. Dump it first, or run the migrations.")
    end
  end

  # Raised when a Crystal schema file exists but was never compiled into this
  # program, so no `Grant::Schema.define` from it is registered.
  class SchemaNotCompiled < Grant::ErrorBase
    getter path : ::String

    def initialize(@path : ::String)
      super("#{@path} is not loaded: require it (it calls Grant::Schema.define) before loading the schema")
    end
  end

  # A `Grant::Schema.define` block and the file it came from.
  struct Definition
    getter version : Int64
    getter source : ::String
    getter body : Proc(SchemaStatements, Nil)

    def initialize(@version : Int64, @source : ::String, @body : Proc(SchemaStatements, Nil))
    end
  end

  @@definitions = [] of Definition
  @@definitions_mutex = Mutex.new

  # Registers the schema a dumped file describes. The block receives the
  # schema statements (`create_table`, `add_foreign_key`, ...) and runs when the
  # schema is loaded, not when this is called:
  #
  # ```
  # # db/schema.cr, written by Grant::Schema::Dumper
  # Grant::Schema.define(version: 20260101120000) do |schema|
  #   schema.create_table "users", id: :bigint, force: :cascade do |t|
  #     t.string "email", null: false
  #   end
  # end
  # ```
  #
  # Crystal compiles and does not interpret, so the file must be `require`d
  # into the program that loads it. The definition is registered under the
  # file's path (`__FILE__`); `Grant::Schema.load(adapter, path)` finds it by
  # that path.
  def self.define(version : Int64, source : ::String = __FILE__, &body : SchemaStatements ->) : Nil
    @@definitions_mutex.synchronize { @@definitions << Definition.new(version, source, body) }
  end

  # Forgets every registered definition. For specs.
  def self.clear_definitions! : Nil
    @@definitions_mutex.synchronize { @@definitions.clear }
  end

  # The definition registered for *path*, or nil.
  def self.definition_for(path : ::String) : Definition?
    wanted = File.expand_path(path)
    suffix = "/" + path.lstrip("./")
    @@definitions_mutex.synchronize do
      @@definitions.reverse_each.find { |candidate| File.expand_path(candidate.source) == wanted || candidate.source.ends_with?(suffix) }
    end
  end

  # Loads the schema file *path* into *adapter*'s database; see `Loader`.
  def self.load(adapter : Grant::Adapter::Base, path : ::String, **options) : Int64
    Loader.new(adapter, **options).load(path)
  end

  # Creates a schema on a database from a Crystal definition, a snapshot, or a
  # SQL structure file, then records the migration versions the schema
  # contains, so `migrate` has nothing left to run.
  #
  # ```
  # Grant::Schema::Loader.new(User.adapter, environment: "development").load("db/schema.cr")
  # ```
  #
  # A Crystal schema runs in one transaction on PostgreSQL and SQLite. A
  # `.sql` file is run statement by statement on SQLite and through `psql` on
  # PostgreSQL; MySQL has no transactional DDL and uses the `mysql` client.
  #
  # With an `environment`, the load refuses to run against a database
  # recorded as (or named as) a protected environment unless `force: true`
  # (`ProtectedEnvironmentError`).
  class Loader
    getter adapter : Grant::Adapter::Base
    getter dialect : Dialect
    getter environment : ::String?

    def initialize(@adapter : Grant::Adapter::Base, @environment : ::String? = nil,
                   @protected_environments : Array(::String) = InternalMetadata::DEFAULT_PROTECTED,
                   @tracking : Tracking = Tracking::Grant, @known_versions : Array(Int64) = [] of Int64,
                   @force : Bool = false)
      @dialect = Dialect.for(@adapter)
    end

    # Loads *path* by its extension (`.sql` is a structure file, anything else
    # a compiled Crystal schema) and returns the schema version.
    def load(path : ::String) : Int64
      if path.ends_with?(".sql")
        load_sql(path)
      else
        definition = Schema.definition_for(path)
        if definition.nil?
          raise SchemaFileMissing.new(path) unless File.exists?(path)
          raise SchemaNotCompiled.new(path)
        end
        load_definition(definition)
      end
    end

    # Runs a registered `Grant::Schema.define` block.
    def load_definition(definition : Definition) : Int64
      guard!
      statements = AdapterStatements.new(@adapter)
      statements.transaction(rebuilds: true) do |scope|
        definition.body.call(scope)
      end
      finish(definition.version)
      definition.version
    end

    # Replays a dump taken with `Dumper#snapshot`.
    def load_snapshot(snapshot : SchemaSnapshot) : Int64
      guard!
      statements = AdapterStatements.new(@adapter)
      statements.transaction(rebuilds: true) do |scope|
        snapshot.apply(scope)
      end
      finish(snapshot.version)
      snapshot.version
    end

    # Runs a SQL structure file written by `Dumper#dump_structure`. The file
    # carries its own `schema_migrations` rows.
    def load_sql(path : ::String) : Int64
      raise SchemaFileMissing.new(path) unless File.exists?(path)
      guard!
      case @dialect
      in .sqlite? then load_sqlite_structure(path)
      in .pg?     then run_tool("psql", ["--set=ON_ERROR_STOP=1", "--quiet", "--no-psqlrc", "--file=#{path}"] + pg_arguments, "PGPASSWORD")
      in .mysql?  then run_mysql(path)
      end
      @adapter.reset_schema_caches!
      metadata = InternalMetadata.new(@adapter)
      if (current = @environment) && metadata.environment.nil?
        metadata.record_environment(current)
      end
      SchemaMigration.new(@adapter, @tracking).current_version
    end

    private def guard! : Nil
      return if @force
      current = @environment || return
      InternalMetadata.new(@adapter).check_protected_environments!(current, @protected_environments, false)
    end

    # Marks *version* and every known migration up to it as applied, and
    # records the environment.
    private def finish(version : Int64) : Nil
      migration = SchemaMigration.new(@adapter, @tracking)
      migration.create_table
      applied = migration.versions
      wanted = (@known_versions.select { |known| known <= version } + [version]).uniq!.reject { |known| known == 0 || applied.includes?(known) }
      record_versions(migration, wanted.sort!)
      if current = @environment
        metadata = InternalMetadata.new(@adapter)
        metadata.record_environment(current) if metadata.environment.nil?
      end
    end

    # One multi-row `INSERT` for the Grant table, one row per version for
    # Micrate's history table.
    private def record_versions(migration : SchemaMigration, versions : Array(Int64)) : Nil
      return if versions.empty?
      if @tracking.micrate?
        versions.each { |version| migration.record(version) }
      else
        rows = versions.map { |version| "('#{version}')" }.join(", ")
        @adapter.open { |db| db.exec "INSERT INTO #{@dialect.quote(SchemaMigration::TABLE)} (version) VALUES #{rows}" }
      end
    end

    private def load_sqlite_structure(path : ::String) : Nil
      statements = File.read(path).split(/^#{Regex.escape(Dumper::STATEMENT_MARKER)}\n/m).map(&.strip).reject(&.empty?)
      executor = AdapterStatements.new(@adapter)
      executor.transaction(rebuilds: true) do |scope|
        statements.each { |sql| scope.execute(sql.rchop(';')) }
      end
    end

    private def pg_arguments : Array(::String)
      ConnectionSettings.parse(@adapter.url).pg_arguments
    end

    private def run_mysql(path : ::String) : Nil
      settings = ConnectionSettings.parse(@adapter.url)
      executable = Process.find_executable("mysql") || raise StructureToolError.new("mysql was not found on the PATH; it is needed to load a structure file")
      error = IO::Memory.new
      status = File.open(path) do |file|
        Process.run(executable, settings.mysql_arguments, env: settings.environment("MYSQL_PWD"), input: file, error: error)
      end
      raise StructureToolError.new("mysql failed (#{status.exit_code}): #{error.to_s.strip}") unless status.success?
    end

    private def run_tool(program : ::String, arguments : Array(::String), password_variable : ::String) : Nil
      executable = Process.find_executable(program) || raise StructureToolError.new("#{program} was not found on the PATH; it is needed to load a structure file")
      settings = ConnectionSettings.parse(@adapter.url)
      error = IO::Memory.new
      status = Process.run(executable, arguments, env: settings.environment(password_variable), output: Process::Redirect::Close, error: error)
      raise StructureToolError.new("#{program} failed (#{status.exit_code}): #{error.to_s.strip}") unless status.success?
    end
  end
end
