require "./migration"
require "./schema_migration"
require "./internal_metadata"
require "../advisory_lock"

module Grant::Schema
  # Raised when a version is asked for that no migration has.
  class UnknownMigrationVersion < Grant::ErrorBase
    def initialize(version : Int64)
      super("No migration with version number #{version}")
    end
  end

  # Raised by `MigrationContext#check_pending!` when migrations have not run.
  class PendingMigrationError < Grant::ErrorBase
    getter versions : Array(Int64)

    def initialize(@versions : Array(Int64))
      super("Migrations are pending: #{@versions.join(", ")}. Run the migrations before continuing.")
    end
  end

  # One row of `MigrationContext#status`.
  struct MigrationStatus
    NO_FILE = "********** NO FILE **********"

    getter version : Int64
    getter name : ::String
    getter? applied : Bool
    # True for a version the database recorded but no migration file has.
    getter? missing : Bool

    def initialize(@version : Int64, @name : ::String, @applied : Bool, @missing : Bool = false)
    end

    def state : ::String
      applied? ? "up" : "down"
    end

    def to_s(io : IO) : Nil
      io << state.ljust(4) << "  " << version << "  " << name
    end
  end

  # Runs a set of migrations (Crystal classes and Micrate `.sql` files) against
  # one database and keeps the record of what has run.
  #
  # ```
  # context = Grant::Schema::MigrationContext.for(User.adapter, CreateUsers, AddAge,
  #   paths: ["db/migrations"], environment: "development")
  # context.migrate                 # everything pending
  # context.migrate(20240101120000) # up or down to that version
  # context.rollback(2)
  # context.redo
  # context.status.each { |row| puts row }
  # ```
  #
  # Every operation that changes the database runs under an advisory lock
  # (`Grant::AdvisoryLock`) held on the connection that runs the DDL, so two
  # deploy nodes never run the same migration twice, and releases it when the
  # operation ends or its connection dies. Versions are read with one `SELECT`
  # per operation. Each migration runs in its own transaction where the
  # database has transactional DDL (see `Migration.disable_ddl_transaction!`),
  # and its version is recorded in that transaction.
  #
  # `tracking: Grant::Schema::Tracking::Micrate` keeps versions in the
  # `micrate_db_version` table of an existing Micrate install instead of
  # `schema_migrations`.
  class MigrationContext
    getter adapter : Grant::Adapter::Base
    getter tracking : Tracking
    getter schema_migration : SchemaMigration
    getter internal_metadata : InternalMetadata
    getter environment : ::String?
    getter lock_timeout : Time::Span
    getter? dry_run : Bool
    getter tenant : ::String?

    @entries : Array(MigrationEntry)
    @paths : Array(::String)
    @loaded : Array(MigrationEntry)?
    @output : IO?
    @verbose : Bool

    def initialize(@adapter : Grant::Adapter::Base, migrations : Array(MigrationEntry) = [] of MigrationEntry,
                   paths : Array(::String) = [] of ::String, @tracking : Tracking = Tracking::Grant,
                   @output : IO? = nil, @verbose : Bool = true, @environment : ::String? = nil,
                   @lock_timeout : Time::Span = 10.minutes, @dry_run : Bool = false, @tenant : ::String? = nil)
      @entries = migrations
      @paths = paths
      @schema_migration = SchemaMigration.new(@adapter, @tracking)
      @internal_metadata = InternalMetadata.new(@adapter)
      @executor = AdapterStatements.new(@adapter)
    end

    # A context over the given migration classes (and `paths:` of `.sql` files).
    def self.for(adapter : Grant::Adapter::Base, *classes : Migration.class, **options) : MigrationContext
      new(adapter, classes.map(&.entry).to_a, **options)
    end

    # A context over every class that declared a `migration_version`.
    def self.registered(adapter : Grant::Adapter::Base, **options) : MigrationContext
      new(adapter, Migration.registry.dup, **options)
    end

    # A context for a named connection (and shard) of the connection registry.
    def self.for_connection(database : ::String, shard : Symbol? = nil, migrations : Array(MigrationEntry) = [] of MigrationEntry, **options) : MigrationContext
      new(ConnectionRegistry.get_adapter(database, :primary, shard), migrations, **options)
    end

    # ---- reading ------------------------------------------------------------

    # Every migration, oldest first. Files are read once per context.
    def migrations : Array(MigrationEntry)
      @loaded ||= load_entries
    end

    # The versions the database has recorded, from one `SELECT`.
    def applied_versions : Set(Int64)
      in_scope { @schema_migration.versions }
    end

    def current_version : Int64
      applied_versions.max? || 0_i64
    end

    # Migrations that have not run, oldest first.
    def pending : Array(MigrationEntry)
      applied = applied_versions
      migrations.reject { |entry| applied.includes?(entry.version) }
    end

    def needs_migration? : Bool
      !pending.empty?
    end

    def check_pending! : Nil
      versions = pending.map(&.version)
      raise PendingMigrationError.new(versions) unless versions.empty?
    end

    # Up or down for every migration, plus a row for each recorded version no
    # file backs.
    def status : Array(MigrationStatus)
      applied = applied_versions
      known = migrations.map { |entry| MigrationStatus.new(entry.version, entry.name, applied.includes?(entry.version)) }
      files = migrations.map(&.version).to_set
      missing = applied.reject { |version| files.includes?(version) }
        .map { |version| MigrationStatus.new(version, MigrationStatus::NO_FILE, true, true) }
      (known + missing).sort_by!(&.version)
    end

    # ---- running ------------------------------------------------------------

    # Brings the database to *target*: migrations newer than it are rolled
    # back, older pending ones run. Without a target every pending migration
    # runs. `0` rolls everything back. Returns the versions that ran, in order.
    def migrate(target : Int64? = nil) : Array(Int64)
      with_migration_lock { migrate_locked(target) }
    end

    # Rolls back the last *step* applied migrations.
    def rollback(step : Int32 = 1) : Array(Int64)
      with_migration_lock { rollback_locked(step) }
    end

    # Runs the next *step* pending migrations.
    def forward(step : Int32 = 1) : Array(Int64)
      with_migration_lock { forward_locked(step) }
    end

    # Rolls back *step* migrations, then migrates forward again to where it was.
    def redo(step : Int32 = 1) : Array(Int64)
      with_migration_lock do
        before = @schema_migration.current_version
        rolled = rollback_locked(step)
        rolled + migrate_locked(before)
      end
    end

    # Runs one migration's `up`; nothing happens if it already ran.
    def up(version : Int64) : Array(Int64)
      with_migration_lock { run_version(version, true) }
    end

    # Runs one migration's `down`; nothing happens if it is not applied.
    def down(version : Int64) : Array(Int64)
      with_migration_lock { run_version(version, false) }
    end

    # Holds the migration advisory lock while the block runs. Used by every
    # operation above; also usable to run several of them as one unit.
    def with_migration_lock(& : -> T) : T forall T
      in_scope do
        if @dry_run
          yield
        else
          Grant::AdvisoryLock.synchronize(@adapter, lock_key, @lock_timeout) do
            @schema_migration.create_table
            if environment = @environment
              @internal_metadata.record_environment(environment) unless @internal_metadata.environment
            end
            yield
          end
        end
      end
    end

    # ---- internals ------------------------------------------------------------

    private def lock_key : ::String
      scope = @tenant ? ":#{@tenant}" : ""
      "grant-migrations:#{@adapter.current_database}#{scope}:#{@schema_migration.table_name}"
    end

    # Runs the block inside the tenant schema, when this context has one.
    private def in_scope(& : -> T) : T forall T
      if schema = @tenant
        Grant::SchemaTenant.with(schema, @adapter) { yield }
      else
        yield
      end
    end

    private def migrate_locked(target : Int64?) : Array(Int64)
      applied = @schema_migration.versions
      ran = [] of Int64
      if target && target != 0 && migrations.none? { |entry| entry.version == target }
        raise UnknownMigrationVersion.new(target)
      end
      limit = target || Int64::MAX
      current = applied.max? || 0_i64
      if target && target < current
        migrations.reverse_each do |entry|
          next unless entry.version > limit && applied.includes?(entry.version)
          run_entry(entry, false, applied)
          ran << entry.version
        end
      end
      migrations.each do |entry|
        next if entry.version > limit || applied.includes?(entry.version)
        run_entry(entry, true, applied)
        ran << entry.version
      end
      ran
    end

    private def rollback_locked(step : Int32) : Array(Int64)
      applied = @schema_migration.versions
      ran = [] of Int64
      applied.to_a.sort!.reverse!.first(step).each do |version|
        entry = migrations.find { |candidate| candidate.version == version } || raise UnknownMigrationVersion.new(version)
        run_entry(entry, false, applied)
        ran << version
      end
      ran
    end

    private def forward_locked(step : Int32) : Array(Int64)
      applied = @schema_migration.versions
      ran = [] of Int64
      migrations.reject { |entry| applied.includes?(entry.version) }.first(step).each do |entry|
        run_entry(entry, true, applied)
        ran << entry.version
      end
      ran
    end

    private def run_version(version : Int64, direction_up : Bool) : Array(Int64)
      entry = migrations.find { |candidate| candidate.version == version } || raise UnknownMigrationVersion.new(version)
      applied = @schema_migration.versions
      return [] of Int64 if applied.includes?(version) == direction_up
      run_entry(entry, direction_up, applied)
      [version]
    end

    # Runs one migration and updates *applied* and the tracking table with it,
    # in the same transaction as the DDL where the database allows one.
    private def run_entry(entry : MigrationEntry, direction_up : Bool, applied : Set(Int64)) : Nil
      migration = entry.build
      recording = @dry_run ? RecordingStatements.new(Dialect.for(@adapter)) : nil
      statements = recording || @executor
      migration.attach(statements, @adapter, @output, @verbose)
      migration.announce(direction_up ? "migrating" : "reverting")
      started = Time.instant
      body = -> do
        direction_up ? migration.up : migration.down
        unless @dry_run
          direction_up ? @schema_migration.record(entry.version) : @schema_migration.forget(entry.version)
        end
      end
      if @dry_run
        body.call
        recording.try(&.statements.each { |sql| migration.write("   #{sql}") })
      else
        @executor.transaction(disable_ddl_transaction: migration.disable_ddl_transaction?, rebuilds: true) { body.call }
      end
      direction_up ? applied.add(entry.version) : applied.delete(entry.version)
      migration.announce(("%s (%.4fs)" % [direction_up ? "migrated" : "reverted", (Time.instant - started).total_seconds]))
      migration.write
    end

    private def load_entries : Array(MigrationEntry)
      all = @entries.dup
      @paths.each do |directory|
        Dir.glob(File.join(directory, "*.sql")).sort!.each do |path|
          all << sql_entry(path)
        end
      end
      all.sort_by!(&.version)
      all.each_cons(2) do |pair|
        if pair[0].version == pair[1].version
          raise InvalidMigration.new("Two migrations have version #{pair[0].version}: #{pair[0].name} and #{pair[1].name}")
        end
      end
      all
    end

    private def sql_entry(path : ::String) : MigrationEntry
      file = File.basename(path)
      match = file.match(/\A(\d+)_(.+)\.sql\z/) || raise InvalidMigration.new("#{path}: a migration file is named <version>_<name>.sql")
      version = match[1].to_i64
      name = match[2].split('_').map(&.capitalize).join
      migration = SqlFileMigration.parse(version, name, File.read(path))
      MigrationEntry.new(version, name, -> { migration.as(Migration) })
    end
  end

  # Raises `PendingMigrationError` when *context* has migrations to run. Call it
  # once at boot or in a spec helper, not per request: it costs one query.
  def self.check_pending!(context : MigrationContext) : Nil
    context.check_pending!
  end

  # Brings the test database up to date before the specs run: when migrations
  # are pending it yields to *load_schema* (a schema file loader) if one is
  # given and migrates otherwise, then checks that nothing is pending.
  def self.maintain_test_schema!(context : MigrationContext, &) : Nil
    if context.needs_migration?
      yield
    end
    context.check_pending!
  end

  def self.maintain_test_schema!(context : MigrationContext) : Nil
    maintain_test_schema!(context) { context.migrate }
  end
end
