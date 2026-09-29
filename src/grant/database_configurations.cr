require "yaml"
require "../adapter/registry"
require "./connection_registry"

module Grant
  # Raised when a database configuration file or lookup is invalid.
  class DatabaseConfigurationError < Grant::ErrorBase
  end

  # One named database of one environment: the typed equivalent of an entry in
  # `database.yml`.
  struct DatabaseConfig
    getter name : String
    getter env : String
    getter adapter : Grant::Adapter::Base.class
    getter url : String
    getter pool_size : Int32
    getter? replica : Bool
    getter? database_tasks : Bool
    # The logical database a replica reads for; `name` for a primary.
    getter database : String

    def initialize(@name, @env, @adapter, @url, @pool_size = 25, @replica = false,
                   @database_tasks = true, database : String? = nil)
      @database = database || @name
    end

    # The connection role this entry registers under.
    def role : Symbol
      replica? ? :reading : :writing
    end

    # The URL scheme, or `nil` if it has none.
    def scheme : String?
      Grant::Adapter::Registry.scheme_of(url)
    end

    # The URL with any credentials replaced, safe to log.
    def redacted_url : String
      Grant::Adapter::Registry.redact(url)
    end
  end

  # Declarative, per-environment multi-database configuration.
  #
  # ```yaml
  # production:
  #   primary:
  #     url: postgres://localhost/app
  #     pool: 10
  #   primary_replica:
  #     url: postgres://replica/app
  #     replica: true          # registered under the reading role of "primary"
  #   analytics:
  #     url: sqlite3:./analytics.db
  #     database_tasks: false
  # ```
  #
  # The adapter comes from the entry's `adapter:` key or, without one, from
  # the URL scheme (`Grant::Adapter::Registry`). For the *current* environment
  # `DATABASE_URL` replaces the url of the primary entry and `<NAME>_DATABASE_URL`
  # (for example `ANALYTICS_DATABASE_URL`) that of the named entry; both
  # create the entry when the file lacks it. The environment is read through
  # the `env_lookup` proc so tests and apps decide where values come from.
  class DatabaseConfigurations
    # The file shape of one entry.
    struct Entry
      include YAML::Serializable

      getter url : String?
      getter adapter : String?
      getter pool : Int32 = 25
      getter replica : Bool = false
      getter database_tasks : Bool = true
      # Logical database this replica belongs to; defaults to the name without
      # a `_replica` suffix.
      getter replica_of : String?

      def initialize(@url = nil, @adapter = nil, @pool = 25, @replica = false,
                     @database_tasks = true, @replica_of = nil)
      end
    end

    alias Source = Hash(String, Hash(String, Entry))

    PRIMARY_NAME = "primary"

    # Reads the process environment; the default for `env_lookup`.
    PROCESS_ENV = ->(key : String) { ENV[key]? }

    getter env : String
    getter configs : Array(DatabaseConfig)

    # Builds the configurations of *source* for the *env* environment.
    def self.load(source : Source, env : String, env_lookup : Proc(String, String?) = PROCESS_ENV) : DatabaseConfigurations
      new(source, env, env_lookup)
    end

    # Loads a YAML file shaped like the example above.
    def self.load(path : String, env : String, env_lookup : Proc(String, String?) = PROCESS_ENV) : DatabaseConfigurations
      parse(File.read(path), env, env_lookup)
    end

    # Loads YAML text.
    def self.parse(yaml : String, env : String, env_lookup : Proc(String, String?) = PROCESS_ENV) : DatabaseConfigurations
      load(Source.from_yaml(yaml), env, env_lookup)
    rescue ex : YAML::ParseException
      raise DatabaseConfigurationError.new("Invalid database configuration: #{ex.message}", cause: ex)
    end

    def initialize(source : Source, @env : String, env_lookup : Proc(String, String?) = PROCESS_ENV)
      @configs = [] of DatabaseConfig
      source.each do |env_name, entries|
        entries = with_url_overrides(entries, env_lookup) if env_name == @env
        entries.each { |name, entry| @configs << build(env_name, name, entry) }
      end
      unless source.has_key?(@env)
        entries = with_url_overrides({} of String => Entry, env_lookup)
        entries.each { |name, entry| @configs << build(@env, name, entry) }
      end
    end

    # The configurations matching the given filters, in file order.
    # `replica: true` returns only replicas, `false` only primaries.
    def configs_for(env : String? = nil, name : String? = nil, include_replicas : Bool = true) : Array(DatabaseConfig)
      @configs.select do |config|
        (env.nil? || config.env == env) &&
          (name.nil? || config.name == name) &&
          (include_replicas || !config.replica?)
      end
    end

    # The single configuration named *name* for *env* (the current environment
    # by default) or `nil`.
    def find_db_config(name : String, env : String = @env) : DatabaseConfig?
      configs_for(env: env, name: name).first?
    end

    # As `find_db_config`, raising `DatabaseConfigurationError` when absent.
    def db_config(name : String, env : String = @env) : DatabaseConfig
      find_db_config(name, env) || raise DatabaseConfigurationError.new(
        "No database configuration named #{name.inspect} for #{env.inspect}")
    end

    # The primary (non-replica) configuration of logical database *database*
    # for the current environment, or its replica when *replica* is true.
    def config_for_database(database : String, replica : Bool = false) : DatabaseConfig?
      @configs.find { |config| config.env == @env && config.database == database && config.replica? == replica }
    end

    # Registers the current environment's connections with
    # `Grant::ConnectionRegistry`. Primaries register under the writing role,
    # replicas under the reading role of their database with increasing replica
    # indexes. Returns the configurations that were registered.
    def establish_connections : Array(DatabaseConfig)
      replica_counts = Hash(String, Int32).new(0)
      configs_for(env: @env).each do |config|
        index = 0
        if config.replica?
          index = replica_counts[config.database]
          replica_counts[config.database] = index + 1
        end
        Grant::ConnectionRegistry.establish_connection(
          database: config.database, adapter: config.adapter, url: config.url,
          role: config.role, pool_size: config.pool_size, replica_index: index)
      end
      configs_for(env: @env)
    end

    private def with_url_overrides(entries : Hash(String, Entry), env_lookup : Proc(String, String?)) : Hash(String, Entry)
      merged = entries.dup
      primary = merged.keys.find { |name| name == PRIMARY_NAME } ||
                merged.each.find { |(_, entry)| !entry.replica }.try(&.first) || PRIMARY_NAME
      names = merged.keys
      names << primary unless names.includes?(primary)
      names.each do |name|
        url = env_lookup.call("#{name.upcase}_DATABASE_URL")
        url ||= env_lookup.call("DATABASE_URL") if name == primary
        next unless url
        next if url.empty?

        existing = merged[name]?
        merged[name] = if existing
                         Entry.new(url, existing.adapter, existing.pool, existing.replica,
                           existing.database_tasks, existing.replica_of)
                       else
                         Entry.new(url: url)
                       end
      end
      merged
    end

    private def build(env_name : String, name : String, entry : Entry) : DatabaseConfig
      url = entry.url || raise DatabaseConfigurationError.new(
        "Database #{name.inspect} in #{env_name.inspect} has no url")
      adapter = if adapter_name = entry.adapter
                  Grant::Adapter::Registry.for_scheme(adapter_name)
                else
                  Grant::Adapter::Registry.for_url(url)
                end
      database = if entry.replica
                   entry.replica_of || name.chomp("_replica")
                 else
                   name
                 end
      DatabaseConfig.new(name, env_name, adapter, url, entry.pool, entry.replica,
        entry.database_tasks, database)
    end
  end

  @@configurations : DatabaseConfigurations?

  # The configurations set by `Grant.configurations=`; raises when none.
  def self.configurations : DatabaseConfigurations
    @@configurations || raise DatabaseConfigurationError.new(
      "Grant.configurations is not set; load one with Grant::DatabaseConfigurations.load")
  end

  # Whether `Grant.configurations=` was called.
  def self.configurations? : DatabaseConfigurations?
    @@configurations
  end

  def self.configurations=(value : DatabaseConfigurations?)
    @@configurations = value
  end

  module ConnectionManagement
    module ClassMethods
      # The `Grant::DatabaseConfig` of the database this model is using: the
      # replica's when the reading role is active and one is configured.
      def connection_db_config : Grant::DatabaseConfig
        configurations = Grant.configurations
        database = current_database
        if Grant::ConnectionManagement.reading_role?(current_role)
          if replica = configurations.config_for_database(database, replica: true)
            return replica
          end
        end
        configurations.config_for_database(database) || raise Grant::DatabaseConfigurationError.new(
          "No database configuration for database #{database.inspect}")
      end
    end
  end
end
