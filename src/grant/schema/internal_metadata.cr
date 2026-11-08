require "./schema_migration"

module Grant::Schema
  # Raised by `InternalMetadata#check_protected_environments!` when the
  # database was created for a protected environment such as production.
  class ProtectedEnvironmentError < Grant::ErrorBase
    getter environment : ::String

    def initialize(@environment : ::String)
      super("You are attempting to run a destructive action against your '#{@environment}' database. Pass force: true if you are sure.")
    end
  end

  # Raised when the stored environment differs from the one asked for.
  class EnvironmentMismatchError < Grant::ErrorBase
    def initialize(current : ::String, stored : ::String)
      super("You are attempting to modify a database that was last run in the '#{stored}' environment, from '#{current}'.")
    end
  end

  # Key-value table (`ar_internal_metadata`, the ActiveRecord name) that keeps
  # the environment a database was created for, so destructive tasks can refuse
  # to run against production.
  class InternalMetadata
    TABLE             = "ar_internal_metadata"
    ENVIRONMENT_KEY   = "environment"
    DEFAULT_PROTECTED = ["production"]

    getter adapter : Grant::Adapter::Base
    getter dialect : Dialect

    @table_present = false

    def initialize(@adapter : Grant::Adapter::Base)
      @dialect = Dialect.for(@adapter)
    end

    def create_table : Nil
      return if @table_present
      @adapter.open do |db|
        db.exec "CREATE TABLE IF NOT EXISTS #{TABLE} (#{@dialect.quote("key")} VARCHAR(255) NOT NULL PRIMARY KEY, " \
                "value VARCHAR(255), created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, " \
                "updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)"
      end
      @table_present = true
    end

    def [](key : ::String) : ::String?
      found = nil.as(::String?)
      return unless @table_present || present?
      @adapter.open do |db|
        found = db.query_one?("SELECT value FROM #{TABLE} WHERE #{@dialect.quote("key")} = #{@dialect.quote_literal(key)}", as: ::String?)
      end
      found
    end

    def []=(key : ::String, value : ::String) : ::String
      create_table
      quoted_key = @dialect.quote("key")
      key_literal = @dialect.quote_literal(key)
      value_literal = @dialect.quote_literal(value)
      @adapter.open do |db|
        case @dialect
        in .mysql?
          db.exec "INSERT INTO #{TABLE} (#{quoted_key}, value) VALUES (#{key_literal}, #{value_literal}) ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = CURRENT_TIMESTAMP"
        in .pg?, .sqlite?
          db.exec "INSERT INTO #{TABLE} (#{quoted_key}, value) VALUES (#{key_literal}, #{value_literal}) ON CONFLICT (#{quoted_key}) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP"
        end
      end
      value
    end

    # The environment this database was created for, if any was recorded.
    def environment : ::String?
      self[ENVIRONMENT_KEY]
    end

    def record_environment(environment : ::String) : Nil
      self[ENVIRONMENT_KEY] = environment
    end

    # Guard for destructive work (drop, purge, reset, schema load). Raises
    # `ProtectedEnvironmentError` when the stored environment, or *current*
    # when nothing was stored, is in *protected_environments*, and `EnvironmentMismatchError`
    # when the database belongs to another environment. `force: true` skips
    # both.
    def check_protected_environments!(current : ::String, protected_environments : Array(::String) = DEFAULT_PROTECTED, force : Bool = false) : Nil
      return if force
      stored = environment
      raise ProtectedEnvironmentError.new(stored) if stored && protected_environments.includes?(stored)
      raise ProtectedEnvironmentError.new(current) if stored.nil? && protected_environments.includes?(current)
      raise EnvironmentMismatchError.new(current, stored) if stored && stored != current
    end

    private def present? : Bool
      found = @adapter.open do |db|
        case @dialect
        in .pg?     then db.query_one("SELECT to_regclass($1) IS NOT NULL", TABLE, as: Bool)
        in .mysql?  then db.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", TABLE).as(Int).to_i64 > 0
        in .sqlite? then db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", TABLE).as(Int).to_i64 > 0
        end
      end
      @table_present = found
    end
  end
end
