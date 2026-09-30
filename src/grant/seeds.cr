require "../adapter/base"
require "./transaction"
require "./adapter/schema"

module Grant
  # Seed data: a `db/seeds.cr` file of `Grant::Seeds.define` blocks, and
  # `load_once` for seed steps that must run exactly once per database.
  #
  # ```
  # # db/seeds.cr
  # Grant::Seeds.define do
  #   Grant::Seeds.load_once("admin-user") { User.create!(email: "admin@example.com") }
  #   Grant::Seeds.load_once("default-roles") { %w(admin member).each { |name| Role.create!(name: name) } }
  # end
  # ```
  #
  # Crystal compiles, it does not interpret: the seeds file is `require`d into
  # the program that runs the tasks, and `define` registers its block under the
  # file's path (`__FILE__`). `Grant::Tasks::Database#seed` (or `Seeds.run`)
  # then runs the blocks registered for `db/seeds.cr`. Running the seeds twice
  # is safe only for steps wrapped in `load_once`.
  #
  # `load_once` records the name in the `grant_seeds` table, in the same
  # transaction as the block, so a block that raises leaves no record and runs
  # again next time, and two processes racing for the same name run it once.
  module Seeds
    TABLE        = "grant_seeds"
    DEFAULT_PATH = "db/seeds.cr"

    # Raised when the seeds file does not exist.
    class SeedFileMissing < Grant::ErrorBase
      getter path : String

      def initialize(@path : String)
        super("Seeds file #{@path} does not exist")
      end
    end

    # Raised when the seeds file exists but no `Seeds.define` from it was
    # compiled into this program.
    class SeedsNotCompiled < Grant::ErrorBase
      getter path : String

      def initialize(@path : String)
        super("#{@path} is not loaded: require it (it calls Grant::Seeds.define) before running the seeds")
      end
    end

    # A registered seeds block and the file it came from.
    struct Block
      getter source : String
      getter body : Proc(Nil)

      def initialize(@source : String, @body : Proc(Nil))
      end
    end

    @@blocks = [] of Block
    @@mutex = Mutex.new
    @@scoped_adapters = {} of Fiber => Grant::Adapter::Base

    # Registers *body* as (part of) the seeds file *source*. The default is the
    # file that calls `define`.
    def self.define(source : String = __FILE__, &body : ->) : Nil
      @@mutex.synchronize { @@blocks << Block.new(source, body) }
    end

    # Forgets every registered block. For specs.
    def self.clear_definitions! : Nil
      @@mutex.synchronize { @@blocks.clear }
    end

    # True when a block from *path* is registered.
    def self.defined?(path : String = DEFAULT_PATH) : Bool
      !blocks_for(path).empty?
    end

    # Runs the blocks registered for *path* in registration order and returns
    # how many ran. `load_once` calls without an adapter inside them use
    # *adapter* (the default connection when nil). Raises `SeedFileMissing`
    # when *path* does not exist and nothing registered for it (a compiled-in
    # file needs no file at runtime), and `SeedsNotCompiled` when it exists but
    # was never required.
    def self.run(path : String = DEFAULT_PATH, adapter : Grant::Adapter::Base? = nil) : Int32
      blocks = blocks_for(path)
      if blocks.empty?
        raise SeedFileMissing.new(path) unless File.exists?(path)
        raise SeedsNotCompiled.new(path)
      end
      with_adapter(adapter) { blocks.each(&.body.call) }
      blocks.size
    end

    # Makes *adapter* the default of `load_once` and friends in this fiber for
    # the duration of the block.
    def self.with_adapter(adapter : Grant::Adapter::Base?, & : -> T) : T forall T
      return yield if adapter.nil?
      fiber = Fiber.current
      previous = @@mutex.synchronize { @@scoped_adapters[fiber]? }
      @@mutex.synchronize { @@scoped_adapters[fiber] = adapter }
      begin
        yield
      ensure
        @@mutex.synchronize do
          if previous
            @@scoped_adapters[fiber] = previous
          else
            @@scoped_adapters.delete(fiber)
          end
        end
      end
    end

    # Runs the block unless a seed called *name* was already recorded on
    # *adapter*. Returns true when the block ran. The record and the block's
    # own writes commit together; a raising block is not recorded.
    def self.load_once(name : String, adapter : Grant::Adapter::Base = default_adapter, & : ->) : Bool
      dialect = Grant::Schema::Dialect.for(adapter)
      ensure_table(adapter, dialect)
      ran = false
      Grant::Transaction.run(adapter, Grant::Transaction::Options.new) do
        if claim(adapter, dialect, name)
          yield
          ran = true
        end
      end
      ran
    end

    # True when the seed *name* was recorded on *adapter*.
    def self.applied?(name : String, adapter : Grant::Adapter::Base = default_adapter) : Bool
      applied(adapter).includes?(name)
    end

    # Names of the recorded seeds, oldest first.
    def self.applied(adapter : Grant::Adapter::Base = default_adapter) : Array(String)
      dialect = Grant::Schema::Dialect.for(adapter)
      ensure_table(adapter, dialect)
      names = [] of String
      sql = "SELECT name FROM #{dialect.quote(TABLE)} ORDER BY applied_at, name"
      adapter.open(sql) do |db|
        db.query_each(sql) { |rs| names << rs.read(String) }
      end
      names
    end

    # Forgets the record of *name*, so its `load_once` block runs again.
    def self.forget(name : String, adapter : Grant::Adapter::Base = default_adapter) : Nil
      dialect = Grant::Schema::Dialect.for(adapter)
      ensure_table(adapter, dialect)
      adapter.open { |db| db.exec "DELETE FROM #{dialect.quote(TABLE)} WHERE name = #{dialect.quote_literal(name)}" }
    end

    # True when a seed was recorded on *adapter* (a database that was seeded
    # once). Does not create the table.
    def self.any_applied?(adapter : Grant::Adapter::Base = default_adapter) : Bool
      dialect = Grant::Schema::Dialect.for(adapter)
      return false unless table_exists?(adapter, dialect)
      sql = "SELECT COUNT(*) FROM #{dialect.quote(TABLE)}"
      count = adapter.open(sql) { |db| db.scalar(sql).as(Int).to_i64 }
      count > 0
    end

    # The adapter of `with_adapter` in this fiber, else the default connection's.
    def self.default_adapter : Grant::Adapter::Base
      scoped = @@mutex.synchronize { @@scoped_adapters[Fiber.current]? }
      scoped || Grant::ConnectionRegistry.get_adapter(Grant::Base.default_database_name)
    end

    private def self.blocks_for(path : String) : Array(Block)
      wanted = File.expand_path(path)
      suffix = "/" + path.lstrip("./")
      @@mutex.synchronize do
        @@blocks.select { |block| File.expand_path(block.source) == wanted || block.source.ends_with?(suffix) }
      end
    end

    private def self.ensure_table(adapter : Grant::Adapter::Base, dialect : Grant::Schema::Dialect) : Nil
      return if table_exists?(adapter, dialect)
      sql = "CREATE TABLE IF NOT EXISTS #{dialect.quote(TABLE)} (name VARCHAR(255) NOT NULL PRIMARY KEY, " \
            "applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)"
      adapter.open(sql) { |db| db.exec sql }
    end

    private def self.table_exists?(adapter : Grant::Adapter::Base, dialect : Grant::Schema::Dialect) : Bool
      adapter.open do |db|
        case dialect
        in .pg?     then db.scalar("SELECT to_regclass($1) IS NOT NULL", TABLE).as(Bool)
        in .mysql?  then db.scalar("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", TABLE).as(Int).to_i64 > 0
        in .sqlite? then db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", TABLE).as(Int).to_i64 > 0
        end
      end
    end

    # Inserts the record; false when it already exists.
    private def self.claim(adapter : Grant::Adapter::Base, dialect : Grant::Schema::Dialect, name : String) : Bool
      table = dialect.quote(TABLE)
      literal = dialect.quote_literal(name)
      sql = if dialect.mysql?
              "INSERT IGNORE INTO #{table} (name) VALUES (#{literal})"
            else
              "INSERT INTO #{table} (name) VALUES (#{literal}) ON CONFLICT (name) DO NOTHING"
            end
      affected = adapter.open(sql) { |db| db.exec(sql).rows_affected }
      affected > 0
    end
  end
end
