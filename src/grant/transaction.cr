module Grant::Transaction
  # Raise this inside a `transaction` block to roll the transaction back without
  # propagating an error past the block. The block returns normally and any
  # `after_rollback` callbacks fire.
  #
  # ```
  # User.transaction do
  #   user.save!
  #   raise Grant::Transaction::Rollback.new # undoes the save, no error escapes
  # end
  # ```
  class Rollback < Exception; end

  # Raised when the database aborts a transaction due to a serialization /
  # concurrency conflict (e.g. a `Serializable` isolation failure or a
  # `could not serialize` error). Retrying the transaction is the usual remedy.
  class SerializationError < Exception
    def initialize(message = "Transaction serialization failure")
      super(message)
    end
  end

  # Raised when a write is attempted inside a `readonly: true` transaction (or
  # when the database reports a "read-only transaction" error).
  class ReadOnlyError < Exception
    def initialize(message = "Cannot modify data in read-only transaction")
      super(message)
    end
  end

  # SQL transaction isolation levels, ordered weakest to strongest. Pass one to
  # `transaction(isolation: ...)` to control how concurrent transactions see one
  # another's changes. Not every adapter honours every level (SQLite maps these
  # onto `BEGIN` / `BEGIN IMMEDIATE` / `BEGIN EXCLUSIVE`).
  #
  # ```
  # User.transaction(isolation: Grant::Transaction::IsolationLevel::Serializable) do
  #   # strongest isolation; may raise SerializationError on conflict
  # end
  # ```
  enum IsolationLevel
    ReadUncommitted
    ReadCommitted
    RepeatableRead
    Serializable

    # Returns the SQL keyword phrase for this level, e.g. `"READ COMMITTED"`.
    # Used when building the adapter-specific `BEGIN` /
    # `SET TRANSACTION ISOLATION LEVEL` statement.
    #
    # ```
    # Grant::Transaction::IsolationLevel::RepeatableRead.to_sql # => "REPEATABLE READ"
    # ```
    def to_sql : String
      case self
      when ReadUncommitted then "READ UNCOMMITTED"
      when ReadCommitted   then "READ COMMITTED"
      when RepeatableRead  then "REPEATABLE READ"
      when Serializable    then "SERIALIZABLE"
      else
        raise "Unknown isolation level: #{self}"
      end
    end
  end

  # Bundle of options for a `transaction`. Construct one directly to reuse the
  # same settings across several `transaction(options)` calls, or pass the
  # individual keyword arguments to `transaction(isolation:, readonly:,
  # requires_new:)` and let it build the `Options` for you.
  #
  # - *isolation* — an `IsolationLevel`, or `nil` for the database default.
  # - *readonly* — open a read-only transaction (writes raise `ReadOnlyError`).
  # - *requires_new* — force a real nested transaction (its own connection)
  #   instead of a savepoint when already inside a transaction.
  #
  # ```
  # opts = Grant::Transaction::Options.new(readonly: true)
  # User.transaction(opts) { User.find!(1) }
  # ```
  record Options,
    isolation : IsolationLevel? = nil,
    readonly : Bool = false,
    requires_new : Bool = false

  # Internal per-transaction bookkeeping: the dedicated `DB::Connection`, the
  # `Options` it was opened with, the owning adapter, the savepoint counter, and
  # the queue of deferred commit/rollback callbacks. Pushed onto a fiber-local
  # stack while a transaction is open; you normally access it via
  # `current_transaction` rather than constructing it yourself.
  class TransactionState
    getter connection : DB::Connection
    getter options : Options
    getter adapter : Grant::Adapter::Base
    getter savepoint_counter : Int32 = 0

    # after_commit/after_rollback closure pairs enqueued by saves/destroys
    # that ran inside THIS transaction (including inside its savepoints).
    # They fire when this transaction's real COMMIT or ROLLBACK executes.
    # Scoping the list per-state (rather than per-fiber) keeps a
    # requires_new inner transaction from draining callbacks that belong to
    # the transaction enclosing it.
    getter pending_callbacks = [] of NamedTuple(on_commit: Proc(Nil), on_rollback: Proc(Nil))

    def initialize(@connection : DB::Connection, @options : Options, @adapter : Grant::Adapter::Base)
    end

    # Returns a fresh, unique savepoint name for the next nested transaction,
    # bumping the internal counter. Names are randomized so re-entrant
    # transactions on the same connection never collide.
    def next_savepoint_name : String
      @savepoint_counter += 1
      "sp_#{@savepoint_counter}_#{Random::Secure.hex(4)}"
    end
  end

  # Module-level fiber-keyed transaction stacks.  All model classes share this
  # single hash so that cross-model transactions (e.g. User.transaction { post.save! })
  # work correctly.  ClassMethods delegates to these module-level helpers so that
  # the Crystal class-variable scoping rule (@@var in an extended module is
  # per-including-class, not per-module) does not create per-model isolated stacks.
  @@transaction_stacks = {} of Fiber => Array(TransactionState)

  # Returns the transaction stack for the current fiber, lazily creating it.
  def self.fiber_stack : Array(TransactionState)
    stack = @@transaction_stacks[Fiber.current]?
    unless stack
      stack = [] of TransactionState
      @@transaction_stacks[Fiber.current] = stack
    end
    stack
  end

  # Removes the current fiber's stack entry (called after the outermost transaction exits).
  def self.clear_fiber_stack
    @@transaction_stacks.delete(Fiber.current)
  end

  # Returns true when the current fiber has at least one explicit transaction open.
  # Used by CommitCallbacks to decide whether to defer or fire immediately.
  def self.in_explicit_transaction? : Bool
    stack = @@transaction_stacks[Fiber.current]?
    !stack.nil? && !stack.empty?
  end

  # Enqueues a commit/rollback callback pair on the innermost open transaction
  # for the current fiber.  The pair fires when THAT transaction's real COMMIT
  # or ROLLBACK executes.  Savepoints do not push a TransactionState, so saves
  # inside a savepoint enqueue onto the enclosing real transaction; a
  # requires_new transaction has its own state, so its callbacks fire at its
  # own (independently durable) commit without touching the enclosing
  # transaction's queue.
  #
  # If no transaction is open the on_commit closure fires immediately — callers
  # normally check in_explicit_transaction? first, so this is a safety net.
  def self.enqueue_pending_callback(on_commit : Proc(Nil), on_rollback : Proc(Nil)) : Nil
    if state = @@transaction_stacks[Fiber.current]?.try(&.last?)
      state.pending_callbacks << {on_commit: on_commit, on_rollback: on_rollback}
    else
      on_commit.call
    end
  end

  # Returns the DB::Connection that is currently enlisted in an open transaction
  # on this fiber, or nil when no transaction is active.  Used by the adapter
  # to route all DML through the transaction connection instead of checking out
  # a fresh pool connection (which would make the DML non-atomic).
  #
  # The calling adapter must be the same instance that opened the transaction:
  # in a multi-database setup (e.g. a SQLite-backed model and a PG-backed model
  # in one process), DML on a model whose adapter did not start the transaction
  # must NOT be routed onto the transaction connection — it belongs to a
  # different database entirely and gets its own pool connection instead.
  def self.current_connection?(adapter : Grant::Adapter::Base) : DB::Connection?
    state = @@transaction_stacks[Fiber.current]?.try(&.last?)
    return nil unless state
    state.adapter.same?(adapter) ? state.connection : nil
  end

  module ClassMethods
    private def transaction_stack : Array(TransactionState)
      Grant::Transaction.fiber_stack
    end

    private def clear_transaction_stack
      Grant::Transaction.clear_fiber_stack
    end

    # Runs *block* inside a database transaction with default options. Every
    # `save`/`update`/`destroy` performed in the block is committed atomically
    # when the block returns; any uncaught exception (or
    # `Grant::Transaction::Rollback`) rolls the whole thing back. Returns `nil`.
    #
    # When called while already inside a transaction, this nests as a
    # **savepoint** (a partial rollback point) rather than a second real
    # transaction — see the `requires_new` overload to force a new one.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    # end
    #
    # User.transaction do
    #   User.create!(email: "a@example.com")
    #   User.create!(email: "b@example.com")
    # end # both committed together; if either raised, neither is saved
    # ```
    def transaction(&block) : Nil
      transaction(Transaction::Options.new) { yield }
    end

    # Runs *block* inside a transaction configured by *options* (a
    # `Transaction::Options`). Returns `nil`. If `options.requires_new` is set,
    # or no transaction is currently open, a real transaction is started;
    # otherwise the block runs in a savepoint nested in the open transaction.
    #
    # ```
    # opts = Grant::Transaction::Options.new(readonly: true)
    # User.transaction(opts) { User.find!(1) }
    # ```
    def transaction(options : Transaction::Options, &block) : Nil
      stack = transaction_stack

      if options.requires_new || stack.empty?
        execute_transaction(options, &block)
      else
        execute_savepoint(&block)
      end
    end

    # Runs *block* inside a transaction, building the options from the given
    # keyword arguments. Returns `nil`. This is the most convenient overload for
    # one-off options.
    #
    # - *isolation* — an `IsolationLevel` (default: database default).
    # - *readonly* — open a read-only transaction; writes raise `ReadOnlyError`.
    # - *requires_new* — force a real nested transaction (own connection) rather
    #   than a savepoint when already inside a transaction.
    #
    # ```
    # User.transaction(isolation: Grant::Transaction::IsolationLevel::Serializable) do
    #   account.update!(balance: account.balance - 100)
    # end
    #
    # # Nested, independently-committing inner transaction:
    # User.transaction do
    #   outer.save!
    #   User.transaction(requires_new: true) { inner.save! }
    # end
    # ```
    def transaction(isolation : IsolationLevel? = nil, readonly : Bool = false, requires_new : Bool = false, &block) : Nil
      options = Transaction::Options.new(
        isolation: isolation,
        readonly: readonly,
        requires_new: requires_new
      )
      transaction(options, &block)
    end

    # Returns `true` when the current fiber has at least one explicit
    # transaction open, `false` otherwise.
    #
    # ```
    # User.transaction_open?                      # => false
    # User.transaction { User.transaction_open? } # => true (inside the block)
    # ```
    def transaction_open? : Bool
      !transaction_stack.empty?
    end

    # Returns the innermost open `TransactionState` for the current fiber, or
    # `nil` when no transaction is open. Mostly useful for introspection (e.g.
    # checking `current_transaction.try(&.options.readonly)`).
    #
    # ```
    # User.transaction { User.current_transaction } # => a TransactionState
    # User.current_transaction                      # => nil (outside a block)
    # ```
    def current_transaction : TransactionState?
      transaction_stack.last?
    end

    private def execute_transaction(options : Transaction::Options, &block)
      # Use open_pool_connection (not open) so that:
      #   1. We always get a dedicated connection for this transaction's BEGIN/COMMIT.
      #   2. requires_new: true transactions get a fresh connection independent of any
      #      enclosing transaction, rather than inheriting the outer tx connection.
      adapter.open_pool_connection do |conn|
        start_transaction(conn, options)
        state = TransactionState.new(conn, options, adapter)
        transaction_stack.push(state)

        begin
          yield

          conn.exec("COMMIT")
          transaction_stack.pop
          clear_transaction_stack if transaction_stack.empty?
          # This transaction committed durably on its own connection — true
          # even for a requires_new transaction nested inside another one —
          # so its deferred after_commit callbacks fire now.  Callbacks
          # enqueued by an enclosing transaction live on that transaction's
          # own state and wait for its commit.
          state.pending_callbacks.each(&.[:on_commit].call)
        rescue ex : Rollback
          conn.exec("ROLLBACK")
          transaction_stack.pop
          clear_transaction_stack if transaction_stack.empty?
          state.pending_callbacks.each(&.[:on_rollback].call)
        rescue ex
          conn.exec("ROLLBACK")
          transaction_stack.pop
          clear_transaction_stack if transaction_stack.empty?
          state.pending_callbacks.each(&.[:on_rollback].call)
          raise ex
        end
      end
    rescue ex : DB::Error
      handle_transaction_error(ex)
    end

    private def execute_savepoint(&block)
      current = transaction_stack.last
      savepoint_name = current.next_savepoint_name
      # Releasing a savepoint is NOT a commit: callbacks enqueued inside it
      # stay pending on the enclosing transaction's state.  But a savepoint
      # ROLLBACK undoes that work permanently, so callbacks enqueued after
      # this mark are pruned and get after_rollback instead of waiting around
      # to incorrectly receive after_commit at the outer commit.
      mark = current.pending_callbacks.size

      begin
        current.connection.exec("SAVEPOINT #{savepoint_name}")
        yield
        current.connection.exec("RELEASE SAVEPOINT #{savepoint_name}")
      rescue ex : Rollback
        current.connection.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
        fire_savepoint_rollback_callbacks(current, mark)
      rescue ex
        current.connection.exec("ROLLBACK TO SAVEPOINT #{savepoint_name}")
        fire_savepoint_rollback_callbacks(current, mark)
        raise ex
      end
    rescue ex : DB::Error
      handle_transaction_error(ex)
    end

    private def fire_savepoint_rollback_callbacks(state : TransactionState, mark : Int32)
      pruned = state.pending_callbacks.pop(state.pending_callbacks.size - mark)
      pruned.each(&.[:on_rollback].call)
    end

    private def start_transaction(conn : DB::Connection, options : Transaction::Options)
      # MySQL: SET TRANSACTION ISOLATION LEVEL must be issued BEFORE START TRANSACTION.
      # (Issuing it after START TRANSACTION silently applies to the *next* transaction.)
      if options.isolation && adapter.class == Grant::Adapter::Mysql.class
        conn.exec("SET TRANSACTION ISOLATION LEVEL #{options.isolation.not_nil!.to_sql}")
      end

      sql = case adapter.class
            when Grant::Adapter::Pg.class
              build_pg_transaction_sql(options)
            when Grant::Adapter::Mysql.class
              build_mysql_transaction_sql(options)
            when Grant::Adapter::Sqlite.class
              build_sqlite_transaction_sql(options)
            else
              "BEGIN"
            end

      conn.exec(sql)
    end

    private def build_pg_transaction_sql(options : Transaction::Options) : String
      parts = ["BEGIN"]

      if isolation = options.isolation
        parts << "ISOLATION LEVEL #{isolation.to_sql}"
      end

      if options.readonly
        parts << "READ ONLY"
      else
        parts << "READ WRITE"
      end

      parts.join(" ")
    end

    private def build_mysql_transaction_sql(options : Transaction::Options) : String
      if options.readonly
        "START TRANSACTION READ ONLY"
      else
        "START TRANSACTION"
      end
    end

    private def build_sqlite_transaction_sql(options : Transaction::Options) : String
      isolation = options.isolation
      case isolation
      when nil
        "BEGIN"
      when .serializable?
        "BEGIN EXCLUSIVE"
      when .read_uncommitted?
        "BEGIN DEFERRED"
      else
        "BEGIN IMMEDIATE"
      end
    end

    private def handle_transaction_error(ex : DB::Error)
      message = ex.message || ""

      case message
      when /deadlock/i
        raise Grant::Locking::DeadlockError.new(message)
      when /serialization failure/i, /could not serialize/i
        raise Transaction::SerializationError.new(message)
      when /read-only transaction/i
        raise Transaction::ReadOnlyError.new(message)
      else
        raise ex
      end
    end
  end

  # Instance-level convenience that delegates to the class-level `transaction`
  # with default options, so you can write `user.transaction { ... }`. Returns
  # `nil`. The transaction is still scoped to the model class's connection, not
  # to this single record.
  #
  # ```
  # user.transaction do
  #   user.save!
  #   user.posts.first.destroy!
  # end
  # ```
  def transaction(&block) : Nil
    self.class.transaction { yield }
  end

  # Instance-level convenience that delegates to the class-level
  # `transaction(options)`. Returns `nil`.
  #
  # ```
  # user.transaction(Grant::Transaction::Options.new(requires_new: true)) do
  #   user.save!
  # end
  # ```
  def transaction(options : Transaction::Options, &block) : Nil
    self.class.transaction(options) { yield }
  end
end
