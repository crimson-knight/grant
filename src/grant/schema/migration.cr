require "./command_recorder"

module Grant::Schema
  # Raised for a migration that cannot run as written: no `change`, `up` or
  # `down`, a SQL file with statements before its `Up` marker, a duplicate
  # version.
  class InvalidMigration < Grant::ErrorBase
  end

  # :nodoc:
  class NoChangeDefined < Grant::ErrorBase
  end

  # A registered migration: its version, its name and how to build it.
  struct MigrationEntry
    getter version : Int64
    getter name : ::String
    getter factory : Proc(Migration)

    def initialize(@version : Int64, @name : ::String, @factory : Proc(Migration))
    end

    def build : Migration
      @factory.call
    end
  end

  # Base class of a Crystal migration. Write `change` for steps with an
  # automatic inverse, or `up` and `down` for anything else:
  #
  # ```
  # class CreateUsers < Grant::Schema::Migration
  #   migration_version 20240101120000
  #
  #   def change
  #     create_table :users do |t|
  #       t.string :email, null: false
  #       t.timestamps
  #     end
  #     add_index :users, :email, unique: true
  #   end
  # end
  # ```
  #
  # The schema methods (`create_table`, `add_column`, `add_index`, ...) are the
  # ones of `Grant::Schema::SchemaStatements`. Inside `change` each call is
  # recorded with its inverse, so rolling back replays the inverses in reverse
  # order. A step with no inverse (`execute`, `change_column`, ...) makes the
  # rollback raise `IrreversibleMigration` before anything runs; use
  # `reversible` to give both directions:
  #
  # ```
  # def change
  #   reversible do |direction|
  #     direction.up { execute "UPDATE users SET email = lower(email)" }
  #     direction.down { } # nothing to undo
  #   end
  # end
  # ```
  #
  # `migration_version` is the timestamp of the file name. `disable_ddl_transaction!`
  # runs the migration outside a transaction (needed for
  # `add_index ..., algorithm: :concurrently` on PostgreSQL).
  abstract class Migration
    @@registry = [] of MigrationEntry

    # Every class that declared `migration_version`, in load order.
    def self.registry : Array(MigrationEntry)
      @@registry
    end

    def self.register(entry : MigrationEntry) : Nil
      @@registry << entry
    end

    # The registry entry of this class; `migration_version` defines it.
    def self.entry : MigrationEntry
      raise InvalidMigration.new("#{self} declares no migration_version")
    end

    # Declares the version of the migration class. Also registers the class in
    # `Migration.registry` and defines `.entry`.
    macro migration_version(version)
      def self.version : ::Int64
        {{version}}.to_i64
      end

      def self.entry : ::Grant::Schema::MigrationEntry
        ::Grant::Schema::MigrationEntry.new(version, {{@type.name.stringify}}, -> { {{@type}}.new.as(::Grant::Schema::Migration) })
      end

      def version : ::Int64
        {{version}}.to_i64
      end

      def name : ::String
        {{@type.name.stringify}}
      end

      ::Grant::Schema::Migration.register(entry)
    end

    # Runs this migration outside a transaction. SQLite and PostgreSQL wrap a
    # migration in one by default; MySQL cannot roll back DDL and never does.
    macro disable_ddl_transaction!
      def disable_ddl_transaction? : ::Bool
        true
      end
    end

    # What `up`/`down` hand to the block of `reversible`.
    class Direction
      @up : Proc(Nil)?
      @down : Proc(Nil)?

      def up(&block : ->) : Nil
        @up = block
      end

      def down(&block : ->) : Nil
        @down = block
      end

      # :nodoc:
      def run_up : Nil
        @up.try(&.call)
      end

      # :nodoc:
      def run_down : Nil
        @down.try(&.call)
      end
    end

    @statements : SchemaStatements?
    @adapter : Grant::Adapter::Base?
    @output : IO?
    @verbose = true
    @recorder = CommandRecorder.new

    abstract def version : Int64
    abstract def name : String

    def disable_ddl_transaction? : Bool
      false
    end

    # Connects the migration to the database (or recording mock) it runs on.
    # The migration context calls this.
    def attach(statements : SchemaStatements, adapter : Grant::Adapter::Base, output : IO? = nil, verbose : Bool = true) : self
      @statements = statements
      @adapter = adapter
      @output = output
      @verbose = verbose
      self
    end

    def statements : SchemaStatements
      @statements || raise InvalidMigration.new("#{name} is not attached to a database; run it through a MigrationContext")
    end

    def adapter : Grant::Adapter::Base
      @adapter || raise InvalidMigration.new("#{name} is not attached to a database; run it through a MigrationContext")
    end

    def dialect : Dialect
      statements.dialect
    end

    # Override for a change that has an automatic inverse.
    def change : Nil
      raise NoChangeDefined.new("#{name} defines no change")
    end

    # Applies the migration. Defaults to `change`.
    def up : Nil
      change
    rescue NoChangeDefined
      raise InvalidMigration.new("#{name} defines none of change, up and down")
    end

    # Undoes the migration. Defaults to `change` run backwards.
    def down : Nil
      revert { change }
    rescue NoChangeDefined
      raise IrreversibleMigration.new("#{name} defines up but no down or change")
    end

    # Runs the block's schema calls backwards: each one's inverse, last first.
    # Raises `IrreversibleMigration` before running anything if a call has no
    # inverse. Inside a `change` that is itself being reversed, the block runs
    # forwards.
    def revert(& : ->) : Nil
      commands = @recorder.capture { yield }
      reversed = commands.reverse.map(&.reversed)
      if @recorder.recording?
        reversed.each { |command| @recorder.add(command) }
      else
        replay(reversed)
      end
    end

    # Gives a direction for each side. In `change`, the `up` block runs when
    # migrating and the `down` block when rolling back.
    def reversible(& : Direction ->) : Nil
      direction = Direction.new
      yield direction
      if @recorder.recording?
        @recorder.add(Command.new("reversible",
          ->(_s : SchemaStatements) { direction.run_up; nil },
          ->(_s : SchemaStatements) { direction.run_down; nil }, "reversible"))
      else
        direction.run_up
      end
    end

    # Runs the block only when migrating up; a rollback skips it.
    def up_only(&block : ->) : Nil
      reversible { |direction| direction.up(&block) }
    end

    # Raw SQL, run on the migration's connection (and only printed in a dry
    # run). It has no inverse: wrap it in `reversible` to roll it back.
    def execute(sql : String) : Nil
      if @recorder.recording?
        @recorder.execute(sql)
      else
        say_with_time("execute(#{sql.inspect})") { statements.execute(sql) }
      end
    end

    {% for name in %w(drop_table create_join_table add_timestamps remove_timestamps drop_join_table
                     add_column remove_column remove_columns change_column change_column_null change_column_default
                     rename_column rename_table add_index remove_index rename_index add_reference remove_reference
                     add_foreign_key remove_foreign_key validate_foreign_key add_check_constraint remove_check_constraint
                     validate_check_constraint add_unique_constraint remove_unique_constraint add_exclusion_constraint
                     remove_exclusion_constraint change_table_comment change_column_comment create_enum drop_enum
                     rename_enum add_enum_value rename_enum_value enable_extension disable_extension) %}
      def {{name.id}}(*args, **options) : Nil
        if @recorder.recording?
          @recorder.{{name.id}}(*args, **options)
        else
          say_with_time("{{name.id}}(#{args.map(&.inspect).join(", ")})") do
            statements.{{name.id}}(*args, **options)
          end
        end
      end
    {% end %}

    # The four that take a block of table columns.
    def create_table(*args, **options, &block : TableDefinition ->) : Nil
      if @recorder.recording?
        @recorder.create_table(*args, **options, &block)
      else
        say_with_time("create_table(#{args.map(&.inspect).join(", ")})") do
          statements.create_table(*args, **options, &block)
        end
      end
    end

    def drop_table(*args, **options, &block : TableDefinition ->) : Nil
      if @recorder.recording?
        @recorder.drop_table(*args, **options, &block)
      else
        say_with_time("drop_table(#{args.map(&.inspect).join(", ")})") do
          statements.drop_table(*args, **options)
        end
      end
    end

    def create_join_table(*args, **options, &block : TableDefinition ->) : Nil
      if @recorder.recording?
        @recorder.create_join_table(*args, **options, &block)
      else
        say_with_time("create_join_table(#{args.map(&.inspect).join(", ")})") do
          statements.create_join_table(*args, **options, &block)
        end
      end
    end

    def change_table(*args, **options, &block : AlterTableDefinition ->) : Nil
      if @recorder.recording?
        @recorder.change_table(*args, **options, &block)
      else
        say_with_time("change_table(#{args.map(&.inspect).join(", ")})") do
          statements.change_table(*args, **options, &block)
        end
      end
    end

    def table_exists?(table : String | Symbol) : Bool
      adapter.schema.table_exists?(table.to_s)
    end

    def column_exists?(table : String | Symbol, column : String | Symbol) : Bool
      table_exists?(table) && adapter.schema.columns(table.to_s).any? { |info| info.name == column.to_s }
    end

    # ---- output -------------------------------------------------------------

    # Writes *message*, prefixed with `-- ` (`   -> ` for a *subitem*).
    def say(message : String, subitem : Bool = false) : Nil
      write("#{subitem ? "   ->" : "--"} #{message}")
    end

    # Writes the `== name: migrating ====` banner line.
    def announce(message : String) : Nil
      text = "#{name}: #{message}"
      write("== #{text} #{"=" * Math.max(0, 75 - text.size)}")
    end

    # Runs the block, announcing *message* before it and the time after it; an
    # integer result is reported as a row count.
    def say_with_time(message : String, & : -> T) : T forall T
      say(message)
      started = Time.instant
      result = yield
      say("%.4fs" % (Time.instant - started).total_seconds, true)
      say("#{result} rows", true) if result.is_a?(Int)
      result
    end

    def write(text : String = "") : Nil
      return unless @verbose
      if io = @output
        io.puts text
      else
        Grant::Log.info { text }
      end
    end

    # Silences `say`, `say_with_time` and `announce` inside the block.
    def suppress_messages(& : -> T) : T forall T
      previous = @verbose
      @verbose = false
      begin
        yield
      ensure
        @verbose = previous
      end
    end

    # Replays *commands* forward on the attached statements, announcing each.
    def replay(commands : Array(Command)) : Nil
      commands.each do |command|
        say_with_time(command.name) { command.apply(statements) }
      end
    end
  end

  # A migration read from a Micrate `.sql` file (`-- +micrate Up` /
  # `-- +micrate Down` sections). Built by `MigrationContext`.
  class SqlFileMigration < Migration
    getter version : Int64
    getter name : String
    getter up_statements : Array(String)
    getter down_statements : Array(String)
    getter? no_transaction : Bool

    def initialize(@version : Int64, @name : String, @up_statements : Array(String),
                   @down_statements : Array(String), @no_transaction : Bool = false)
    end

    # Reads a Micrate migration file's text. `-- +micrate Up` and `Down` open a
    # section; `StatementBegin`/`StatementEnd` wrap a statement with semicolons
    # inside (a function body); `NoTransaction` runs the file outside a
    # transaction. Other `--` lines are comments.
    def self.parse(version : Int64, name : String, text : String) : SqlFileMigration
      sections = {up: [] of String, down: [] of String}
      section = nil.as(Symbol?)
      buffer = [] of String
      block = false
      no_transaction = false

      flush = ->(target : Array(String)) do
        sql = buffer.join("\n").strip
        target << sql unless sql.empty?
        buffer.clear
      end

      text.each_line do |raw|
        line = raw.rstrip
        stripped = line.lstrip
        if match = stripped.match(/\A--\s*\+micrate\s+(\w+)/i)
          case match[1].downcase
          when "up"
            raise InvalidMigration.new("#{name}: unterminated StatementBegin") if block
            section = :up
          when "down"
            raise InvalidMigration.new("#{name}: unterminated StatementBegin") if block
            section = :down
          when "statementbegin" then block = true
          when "statementend"
            block = false
            flush.call(section == :down ? sections[:down] : sections[:up])
          when "notransaction" then no_transaction = true
          else
            raise InvalidMigration.new("#{name}: unknown Micrate marker #{match[1].inspect}")
          end
          next
        end
        next if !block && (stripped.empty? || stripped.starts_with?("--"))
        target_section = section
        if target_section.nil?
          raise InvalidMigration.new("#{name}: SQL before the -- +micrate Up marker")
        end
        buffer << line
        if !block && stripped.ends_with?(';')
          flush.call(target_section == :down ? sections[:down] : sections[:up])
        end
      end
      raise InvalidMigration.new("#{name}: unterminated StatementBegin") if block
      raise InvalidMigration.new("#{name}: the last statement is missing its semicolon") unless buffer.empty?
      new(version, name, sections[:up], sections[:down], no_transaction)
    end

    def disable_ddl_transaction? : Bool
      @no_transaction
    end

    def up : Nil
      @up_statements.each { |sql| execute(sql) }
    end

    def down : Nil
      raise IrreversibleMigration.new("#{name} has no -- +micrate Down section") if @down_statements.empty?
      @down_statements.each { |sql| execute(sql) }
    end
  end
end
