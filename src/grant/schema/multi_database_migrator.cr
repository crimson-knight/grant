require "./migration_context"

module Grant::Schema
  # Raised by `MigrationReport#raise_if_failed!`; carries the per-target errors.
  class MigrationFailed < Grant::ErrorBase
    getter failures : Hash(::String, ::Exception)

    def initialize(@failures : Hash(::String, ::Exception))
      super("Migration failed on #{@failures.size} target(s): " + @failures.map { |label, error| "#{label} (#{error.message})" }.join("; "))
    end
  end

  # What one target did in a `MultiDatabaseMigrator` run.
  struct TargetResult
    getter label : ::String
    getter versions_before : Int64
    getter versions_after : Int64
    getter ran : Array(Int64)
    getter error : ::Exception?

    def initialize(@label : ::String, @versions_before : Int64, @versions_after : Int64, @ran : Array(Int64), @error : ::Exception? = nil)
    end

    def failed? : Bool
      !@error.nil?
    end
  end

  # The current version of every target, and which ones lag behind.
  struct SkewReport
    getter versions : Hash(::String, Int64)

    def initialize(@versions : Hash(::String, Int64))
    end

    def latest : Int64
      @versions.values.max? || 0_i64
    end

    # Targets below the newest version any target has.
    def behind : Array(::String)
      @versions.select { |_, version| version < latest }.keys
    end

    def skewed? : Bool
      !behind.empty?
    end
  end

  struct MigrationReport
    getter results : Array(TargetResult)

    def initialize(@results : Array(TargetResult))
    end

    def failed : Array(TargetResult)
      @results.select(&.failed?)
    end

    def succeeded? : Bool
      failed.empty?
    end

    def raise_if_failed! : Nil
      return if succeeded?
      errors = {} of ::String => ::Exception
      failed.each { |result| result.error.try { |error| errors[result.label] = error } }
      raise MigrationFailed.new(errors)
    end
  end

  # Migrates several databases, shards or schema tenants with one call. Each
  # target has its own `MigrationContext` (own migration directory, own
  # `schema_migrations`, own advisory lock), so targets can run side by side;
  # `parallelism` bounds how many do at once. A target that fails does not stop
  # the others or hide behind them: the report lists every target's result and
  # `#skew` shows which ones are behind.
  #
  # ```
  # migrator = Grant::Schema::MultiDatabaseMigrator.for_shards("primary", [:one, :two], migrations: entries)
  # migrator.migrate(parallelism: 2).raise_if_failed!
  # migrator.skew.behind # => []
  # ```
  class MultiDatabaseMigrator
    getter targets : Hash(::String, MigrationContext)

    def initialize(@targets : Hash(::String, MigrationContext))
    end

    # One target per named connection (`{"primary" => [entries], ...}`); `paths`
    # gives each connection's `.sql` directories.
    def self.for_connections(migrations : Hash(::String, Array(MigrationEntry)) = {} of ::String => Array(MigrationEntry),
                             paths : Hash(::String, Array(::String)) = {} of ::String => Array(::String), **options) : MultiDatabaseMigrator
      targets = {} of ::String => MigrationContext
      (migrations.keys + paths.keys).uniq!.each do |database|
        entries = migrations[database]? || ([] of MigrationEntry)
        directories = paths[database]? || ([] of ::String)
        targets[database] = MigrationContext.for_connection(database, nil, entries, **options.merge(paths: directories))
      end
      new(targets)
    end

    # One target per shard of *database*; every shard gets the same migrations.
    def self.for_shards(database : ::String, shards : Array(Symbol) = ConnectionRegistry.shards_for_database(database),
                        migrations : Array(MigrationEntry) = [] of MigrationEntry, **options) : MultiDatabaseMigrator
      targets = {} of ::String => MigrationContext
      shards.each { |shard| targets["#{database}:#{shard}"] = MigrationContext.for_connection(database, shard, migrations, **options) }
      new(targets)
    end

    # One target per PostgreSQL schema tenant of *adapter*, each with its own
    # `schema_migrations` in its own schema.
    def self.for_tenants(adapter : Grant::Adapter::Base, schemas : Array(::String),
                         migrations : Array(MigrationEntry) = [] of MigrationEntry, **options) : MultiDatabaseMigrator
      targets = {} of ::String => MigrationContext
      schemas.each { |schema| targets[schema] = MigrationContext.new(adapter, migrations, **options.merge(tenant: schema)) }
      new(targets)
    end

    # Migrates every target to *target_version* (or the latest), at most
    # *parallelism* at a time.
    def migrate(target_version : Int64? = nil, parallelism : Int32 = 1) : MigrationReport
      run_each(parallelism, &.migrate(target_version))
    end

    def rollback(step : Int32 = 1, parallelism : Int32 = 1) : MigrationReport
      run_each(parallelism, &.rollback(step))
    end

    # Current version of every target.
    def versions : Hash(::String, Int64)
      @targets.transform_values(&.current_version)
    end

    def skew : SkewReport
      SkewReport.new(versions)
    end

    private def run_each(parallelism : Int32, &block : MigrationContext -> Array(Int64)) : MigrationReport
      raise ArgumentError.new("parallelism must be at least 1") if parallelism < 1
      slots = Channel(Nil).new(parallelism)
      done = Channel({::String, TargetResult}).new
      @targets.each do |label, context|
        slots.send(nil)
        spawn do
          before = 0_i64
          result = begin
            before = context.current_version
            ran = block.call(context)
            TargetResult.new(label, before, context.current_version, ran)
          rescue ex
            TargetResult.new(label, before, before, [] of Int64, ex)
          end
          slots.receive
          done.send({label, result})
        end
      end
      results = {} of ::String => TargetResult
      @targets.size.times do
        label, result = done.receive
        results[label] = result
      end
      MigrationReport.new(@targets.keys.map { |label| results[label] })
    end
  end
end
