module Grant
  # Raised when `isolation:` is passed to a transaction that would join or
  # nest inside an already-open transaction on the same connection. The
  # isolation level can only be chosen when the real transaction begins; use
  # `independent: true` to open a separate transaction with its own level.
  class TransactionIsolationError < Grant::ErrorBase
    def initialize(message = "Cannot set the isolation level of a nested transaction; it is fixed by the outermost transaction")
      super(message)
    end
  end
end

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

  # Preserves an IOError escaping a transaction block so the adapter's pool
  # wrapper does not mistake it for a broken connection during cleanup.
  class PreservedIOError < Grant::ErrorBase
    getter original : IO::Error

    def initialize(@original : IO::Error)
      super(@original.message || "I/O error in transaction block")
    end
  end

  # Raised when the database aborts a transaction due to a serialization /
  # concurrency conflict (e.g. a `Serializable` isolation failure or a
  # `could not serialize` error). Retrying the transaction is the usual remedy.
  alias SerializationError = Grant::SerializationFailure

  # Raised when a write is attempted inside a `readonly: true` transaction (or
  # when the database reports a "read-only transaction" error).
  class ReadOnlyError < Grant::ErrorBase
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

  # Raised by the manual transaction API when no transaction is open on the
  # connection, or when a handle is used after it was already committed or
  # rolled back.
  class NotOpenError < Grant::ErrorBase
    def initialize(message = "No open transaction")
      super(message)
    end
  end

  # Raised when a savepoint name is not a safe SQL identifier.
  class InvalidSavepointNameError < Grant::ErrorBase
  end

  SAVEPOINT_NAME_PATTERN = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

  # Bundle of options for a `transaction`. Construct one directly to reuse the
  # same settings across several `transaction(options)` calls, or pass the
  # individual keyword arguments to `transaction(isolation:, readonly:,
  # requires_new:, joinable:, independent:)` and let it build the `Options`.
  #
  # - *isolation* — an `IsolationLevel`, or `nil` for the database default. It
  #   can only be set on the outermost transaction (or an `independent` one);
  #   a nested transaction that sets it raises `Grant::TransactionIsolationError`.
  # - *readonly* — open a read-only transaction (writes raise `ReadOnlyError`).
  # - *requires_new* — when already inside a transaction, open a SAVEPOINT
  #   instead of joining the enclosing transaction. Work inside it is undone by
  #   a `Rollback` (or exception) without undoing the enclosing transaction, and
  #   is also undone if the enclosing transaction rolls back (ActiveRecord parity).
  # - *joinable* — when `false`, a plain nested `transaction` block inside this
  #   one opens a savepoint instead of joining it.
  # - *independent* — Grant-only: open a second, separately committing
  #   transaction on its own pooled connection. It holds two pool connections
  #   for its duration and cannot see the enclosing transaction's uncommitted
  #   rows (it can deadlock against them), so use it sparingly.
  #
  # ```
  # opts = Grant::Transaction::Options.new(readonly: true)
  # User.transaction(opts) { User.find!(1) }
  # ```
  # - *lazy_begin* — hold off sending `BEGIN` until the first statement runs in
  #   the transaction, and send nothing at all when none does (ActiveRecord's
  #   lazy transactions). `save` uses it, so saving a record with nothing to
  #   write costs no round trip.
  record Options,
    isolation : IsolationLevel? = nil,
    readonly : Bool = false,
    requires_new : Bool = false,
    joinable : Bool = true,
    independent : Bool = false,
    lazy_begin : Bool = false

  # Internal per-transaction bookkeeping: the dedicated `DB::Connection`, the
  # `Options` it was opened with, the owning adapter, the savepoint counter, and
  # the queue of deferred commit/rollback callbacks. Pushed onto a fiber-local
  # stack while a real transaction is open; use `current_transaction` (a
  # `Handle`) rather than constructing it yourself.
  class TransactionState
    getter options : Options
    getter adapter : Grant::Adapter::Base
    getter savepoint_counter : Int32 = 0

    # When the transaction began, for the duration of `Events::Transaction`.
    getter started_at : Time::Instant = Time.instant

    # after_commit/after_rollback closure pairs enqueued by saves/destroys
    # that ran inside THIS transaction (including inside its savepoints).
    # They fire when this transaction's real COMMIT or ROLLBACK executes.
    # Scoping the list per-state (rather than per-fiber) keeps an
    # independent inner transaction from draining callbacks that belong to
    # the transaction enclosing it.
    getter pending_callbacks = [] of NamedTuple(on_commit: Proc(Nil), on_rollback: Proc(Nil))

    # Blocks registered with `after_all_transactions_commit`. They run after the
    # outermost transaction commits and are dropped on rollback.
    getter after_all_commit_callbacks = [] of Proc(Nil)

    # Model snapshots taken before each write in this transaction. Keeping
    # every snapshot lets a savepoint restore only the writes made inside it.
    getter list_of_record_rollback_actions = [] of Proc(Nil)

    # Whether a plain nested `transaction` block joins the innermost level.
    property? joinable : Bool = true

    # False once the real COMMIT or ROLLBACK ran.
    getter? open : Bool = true

    # True when opened through the manual `begin_transaction` API.
    property? manual : Bool = false

    # Manually opened savepoint handles, innermost last.
    getter manual_savepoints = [] of Handle

    # True when this state owns a pooled connection that must be released.
    property? owns_connection : Bool = false

    # True while a deferred `BEGIN` (see `Options#lazy_begin`) has not been
    # sent: the transaction exists on the stack but the database knows nothing
    # of it yet.
    getter? begin_pending : Bool = false

    # True when sending the deferred `BEGIN` failed, so the failure belongs to
    # the transaction rather than to the statement that asked for it.
    property? begin_failed : Bool = false

    def initialize(@connection : DB::Connection, @options : Options, @adapter : Grant::Adapter::Base)
      @joinable = @options.joinable
    end

    # The transaction's connection. Asking for it means a statement is about to
    # run on it, so a deferred `BEGIN` is sent first.
    def connection : DB::Connection
      Grant::Transaction.send_deferred_begin(self) if @begin_pending
      @connection
    end

    # The connection without triggering a deferred `BEGIN`.
    #
    # :nodoc:
    def raw_connection : DB::Connection
      @connection
    end

    # :nodoc:
    def defer_begin! : Nil
      @begin_pending = true
    end

    # :nodoc:
    def begin_pending=(value : Bool)
      @begin_pending = value
    end

    def close : Nil
      @open = false
    end

    def handle : Handle
      @handle ||= Handle.new(self)
    end

    @handle : Handle?

    # Returns a fresh savepoint name for the next nested transaction, bumping
    # the per-transaction counter. Unique for the life of this transaction.
    def next_savepoint_name : String
      @savepoint_counter += 1
      "sp_#{@savepoint_counter}"
    end
  end

  # :nodoc:
  # The name of a manually opened savepoint and the sizes of the transaction's
  # queues when it was opened, so rolling back to it can undo only its work.
  record SavepointMarker,
    name : String,
    marks : NamedTuple(callbacks: Int32, records: Int32, after_all: Int32),
    started_at : Time::Instant = Time.instant

  # Public view of a transaction: what `Model.current_transaction` returns and
  # what `Connection#begin_transaction` hands back. When no transaction is open
  # it is a null handle: `open?` is `false` and `after_commit` runs its block
  # immediately (Rails 7.2 `NullTransaction`).
  #
  # ```
  # User.transaction do
  #   User.current_transaction.after_commit { Mailer.deliver_welcome }
  #   User.create!(email: "a@example.com")
  # end # the mail is sent here, only if the transaction committed
  # ```
  class Handle
    getter state : TransactionState?
    @savepoint : SavepointMarker?
    @settled : Bool = false

    # :nodoc:
    def initialize(@state : TransactionState?)
    end

    # :nodoc:
    def initialize(@state : TransactionState, @savepoint : SavepointMarker)
    end

    # Whether the transaction (or manual savepoint) is still open.
    def open? : Bool
      state = @state
      return false unless state
      state.open? && !@settled
    end

    def closed? : Bool
      !open?
    end

    # The isolation level the outermost transaction was opened with, if any.
    def isolation : IsolationLevel?
      @state.try(&.options.isolation)
    end

    def readonly? : Bool
      state = @state
      state ? state.options.readonly : false
    end

    # Registers *block* to run when this transaction commits durably. If the
    # transaction is not open, the block runs immediately. Work registered
    # inside a savepoint that is rolled back is dropped.
    def after_commit(&block : -> Nil) : Nil
      state = @state
      if state && open?
        state.pending_callbacks << {on_commit: block, on_rollback: Proc(Nil).new { }}
      else
        block.call
      end
    end

    # Registers *block* to run if this transaction rolls back. A no-op when the
    # transaction is not open.
    def after_rollback(&block : -> Nil) : Nil
      state = @state
      if state && open?
        state.pending_callbacks << {on_commit: Proc(Nil).new { }, on_rollback: block}
      end
    end

    # Commits a transaction opened with `Connection#begin_transaction`
    # (releases the savepoint for a nested manual handle).
    def commit : Nil
      Grant::Transaction.commit_manual(self)
    end

    # Rolls back a transaction opened with `Connection#begin_transaction`
    # (rolls back to the savepoint for a nested manual handle).
    def rollback : Nil
      Grant::Transaction.rollback_manual(self)
    end

    # :nodoc:
    def savepoint? : SavepointMarker?
      @savepoint
    end

    # :nodoc:
    def settle : Nil
      @settled = true
    end
  end

  # Module-level fiber-keyed transaction stacks.  All model classes share this
  # single hash so that cross-model transactions (e.g. User.transaction { post.save! })
  # work correctly.  ClassMethods delegates to these module-level helpers so that
  # the Crystal class-variable scoping rule (@@var in an extended module is
  # per-including-class, not per-module) does not create per-model isolated stacks.
  #
  # The hash is shared by every fiber (and every thread under
  # `-Dpreview_mt`), so reads and writes of it go through a mutex. Each stack
  # array is owned by its fiber and needs no lock.
  @@transaction_stacks = {} of Fiber => Array(TransactionState)
  @@transaction_stacks_mutex = Mutex.new

  private def self.stack_for_current_fiber? : Array(TransactionState)?
    fiber = Fiber.current
    @@transaction_stacks_mutex.synchronize { @@transaction_stacks[fiber]? }
  end

  # Returns the transaction stack for the current fiber, lazily creating it.
  def self.fiber_stack : Array(TransactionState)
    fiber = Fiber.current
    @@transaction_stacks_mutex.synchronize do
      @@transaction_stacks[fiber] ||= [] of TransactionState
    end
  end

  # Removes the current fiber's stack entry (called after the outermost transaction exits).
  def self.clear_fiber_stack : Nil
    fiber = Fiber.current
    @@transaction_stacks_mutex.synchronize { @@transaction_stacks.delete(fiber) }
    nil
  end

  # Returns true when the current fiber has at least one explicit transaction open.
  # Used by CommitCallbacks to decide whether to defer or fire immediately.
  def self.in_explicit_transaction? : Bool
    stack = stack_for_current_fiber?
    !stack.nil? && !stack.empty?
  end

  # Returns the innermost open state for the current fiber, or `nil`.
  def self.current_state? : TransactionState?
    stack_for_current_fiber?.try(&.last?)
  end

  # Returns the innermost open state on *adapter* for the current fiber, or
  # `nil`. A transaction on another database may be nested inside it, so this
  # searches the whole stack rather than only its top.
  def self.current_state_for?(adapter : Grant::Adapter::Base) : TransactionState?
    stack = stack_for_current_fiber?
    return nil unless stack
    stack.reverse_each do |state|
      return state if state.adapter.same?(adapter)
    end
    nil
  end

  # Returns the `Handle` of the innermost open transaction, or a null handle.
  def self.current_handle : Handle
    if state = current_state?
      state.handle
    else
      Handle.new(nil)
    end
  end

  # Enqueues a commit/rollback callback pair on the innermost open transaction
  # for the current fiber.  The pair fires when THAT transaction's real COMMIT
  # or ROLLBACK executes.  Savepoints do not push a TransactionState, so saves
  # inside a savepoint enqueue onto the enclosing real transaction; an
  # independent transaction has its own state, so its callbacks fire at its
  # own (independently durable) commit without touching the enclosing
  # transaction's queue.
  #
  # If no transaction is open the on_commit closure fires immediately — callers
  # normally check in_explicit_transaction? first, so this is a safety net.
  def self.enqueue_pending_callback(on_commit : Proc(Nil), on_rollback : Proc(Nil)) : Nil
    if state = current_state?
      state.pending_callbacks << {on_commit: on_commit, on_rollback: on_rollback}
    else
      on_commit.call
    end
  end

  # Runs *block* after the outermost open transaction on this fiber commits, or
  # immediately when no transaction is open. Dropped if the transaction (or the
  # savepoint it was registered in) rolls back. State is fiber-local, so a block
  # registered on one fiber never runs on behalf of another fiber's commit.
  #
  # ```
  # Grant.after_all_transactions_commit { Cache.bust("orders") }
  # ```
  def self.after_all_transactions_commit(&block : -> Nil) : Nil
    if state = current_state?
      state.after_all_commit_callbacks << block
    else
      block.call
    end
  end

  # Enlists a record snapshot with the innermost open transaction. The snapshot
  # is discarded on commit and called in reverse order on rollback.
  def self.enlist_record_rollback_action(rollback_action : Proc(Nil)) : Nil
    if state = current_state?
      state.list_of_record_rollback_actions << rollback_action
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
    current_state_for?(adapter).try(&.connection)
  end

  # Runs *block* in a transaction on *adapter* (which must be the writer).
  # Returns the block's value, or `nil` when the block raised `Rollback`.
  #
  # - No transaction open on *adapter*: opens a real transaction.
  # - `independent: true`: opens a separate real transaction on its own
  #   pooled connection.
  # - `requires_new: true`, or the enclosing level is not joinable: opens a
  #   SAVEPOINT, rolled back independently and along with the outer transaction.
  # - Otherwise the block joins the enclosing transaction (a `Rollback` is
  #   swallowed without undoing anything, as in ActiveRecord).
  def self.run(adapter : Grant::Adapter::Base, options : Options, & : -> T) : T? forall T
    state = current_state_for?(adapter)
    return run_real(adapter, options) { yield } unless state

    stack = fiber_stack
    if state.same?(stack.last?)
      run_nested(state, adapter, options) { yield }
    else
      # The open transaction on *adapter* has a transaction on another database
      # nested inside it. Make it the innermost level for the block so saves
      # enlist their callbacks and record snapshots with it, not with the
      # other database's transaction.
      stack.push(state)
      begin
        run_nested(state, adapter, options) { yield }
      ensure
        stack.pop if stack.last?.same?(state)
      end
    end
  end

  private def self.run_nested(state : TransactionState, adapter : Grant::Adapter::Base, options : Options, & : -> T) : T? forall T
    if options.independent
      if Grant::SchemaTenant.current_connection?(adapter) || adapter.pinned_connection?
        # A schema-tenant or pinned-connection block owns one physical
        # connection; a second one would lose its session state, so nest with
        # a savepoint instead.
        return run_savepoint(state, options.joinable, nil) { yield }
      end
      return run_real(adapter, options) { yield }
    end

    if options.isolation
      raise Grant::TransactionIsolationError.new
    end

    if options.requires_new || !state.joinable?
      run_savepoint(state, options.joinable, nil) { yield }
    else
      run_joined { yield }
    end
  end

  private def self.run_joined(& : -> T) : T? forall T
    yield
  rescue Rollback
    nil
  end

  # A savepoint opened directly under a non-joinable level (for example the
  # `Grant::Spec` wrapper) settles its own after_commit callbacks when it is
  # released, as ActiveRecord does (`run_commit_callbacks: !joinable`). Those
  # callbacks run after the release, outside the database-error rescue.
  private def self.run_savepoint(state : TransactionState, joinable : Bool, name : String?, & : -> T) : T? forall T
    outcome = run_savepoint_body(state, joinable, name) { yield }
    if callbacks = outcome[0]
      callbacks.each(&.call)
    end
    outcome[1]
  end

  private def self.run_savepoint_body(state : TransactionState, joinable : Bool, name : String?, & : -> T) : {Array(Proc(Nil))?, T?} forall T
    savepoint_name = name || state.next_savepoint_name
    marks = savepoint_marks(state)
    previous_joinable = state.joinable?
    state.joinable = joinable
    started_at = Time.instant

    begin
      execute_control(state.connection, state.adapter, "SAVEPOINT #{savepoint_name}")
      publish_transaction_start(state, savepoint_name)
      value = yield
      execute_control(state.connection, state.adapter, "RELEASE SAVEPOINT #{savepoint_name}")
      publish_transaction_end(state, Grant::Events::TransactionOutcome::Commit, started_at, savepoint_name)
      {previous_joinable ? nil : take_released_savepoint_callbacks(state, marks), value}
    rescue ex : Rollback
      rollback_to_savepoint(state, savepoint_name, marks)
      publish_transaction_end(state, Grant::Events::TransactionOutcome::Rollback, started_at, savepoint_name)
      {nil, nil}
    rescue ex
      rollback_to_savepoint(state, savepoint_name, marks)
      publish_transaction_end(state, Grant::Events::TransactionOutcome::Rollback, started_at, savepoint_name)
      raise ex
    ensure
      state.joinable = previous_joinable
    end
  rescue ex : DB::Error
    handle_transaction_error(state.adapter, ex)
  end

  # Treats the release of a savepoint under a non-joinable level as that
  # work's commit: its record snapshots are discarded and the after_commit
  # closures enqueued since *marks* are returned for the caller to run.
  private def self.take_released_savepoint_callbacks(state : TransactionState, marks : NamedTuple(callbacks: Int32, records: Int32, after_all: Int32)) : Array(Proc(Nil))
    released_records = state.list_of_record_rollback_actions.size - marks[:records]
    state.list_of_record_rollback_actions.pop(released_records) if released_records > 0

    released_callbacks = state.pending_callbacks.size - marks[:callbacks]
    return [] of Proc(Nil) if released_callbacks <= 0
    state.pending_callbacks.pop(released_callbacks).map(&.[:on_commit])
  end

  private def self.savepoint_marks(state : TransactionState) : NamedTuple(callbacks: Int32, records: Int32, after_all: Int32)
    {
      callbacks: state.pending_callbacks.size,
      records:   state.list_of_record_rollback_actions.size,
      after_all: state.after_all_commit_callbacks.size,
    }
  end

  # Undoes everything after a savepoint mark. Releasing a savepoint is NOT a
  # commit (callbacks stay pending on the enclosing state), but a savepoint
  # ROLLBACK discards that work permanently, so callbacks enqueued after the
  # mark are pruned and get after_rollback (after_all blocks are dropped)
  # rather than waiting to receive after_commit at the outer commit.
  private def self.rollback_to_savepoint(state : TransactionState, name : String, marks : NamedTuple(callbacks: Int32, records: Int32, after_all: Int32)) : Nil
    execute_control(state.connection, state.adapter, "ROLLBACK TO SAVEPOINT #{name}")
    restore_savepoint_records(state, marks[:records])
    prune_after_all(state, marks[:after_all])
    fire_savepoint_rollback_callbacks(state, marks[:callbacks])
  end

  private def self.prune_after_all(state : TransactionState, mark : Int32) : Nil
    excess = state.after_all_commit_callbacks.size - mark
    state.after_all_commit_callbacks.pop(excess) if excess > 0
  end

  private def self.fire_savepoint_rollback_callbacks(state : TransactionState, mark : Int32) : Nil
    excess = state.pending_callbacks.size - mark
    return if excess <= 0
    pruned = state.pending_callbacks.pop(excess)
    pruned.each(&.[:on_rollback].call)
  end

  private def self.restore_savepoint_records(state : TransactionState, mark : Int32) : Nil
    number_to_restore = state.list_of_record_rollback_actions.size - mark
    return if number_to_restore <= 0

    rollback_actions = state.list_of_record_rollback_actions.pop(number_to_restore)
    rollback_actions.reverse_each(&.call)
  end

  private def self.restore_transaction_records(state : TransactionState) : Nil
    state.list_of_record_rollback_actions.reverse_each(&.call)
    state.list_of_record_rollback_actions.clear
  end

  private def self.run_real(adapter : Grant::Adapter::Base, options : Options, & : -> T) : T? forall T
    outcome = begin
      if conn = Grant::SchemaTenant.current_connection?(adapter) || adapter.pinned_connection?
        run_real_on(conn, adapter, options) { yield }
      else
        # Use a dedicated pool checkout outside schema tenancy. Inside a schema
        # block the same already-pinned connection must carry BEGIN through
        # COMMIT so every statement sees the active search_path.
        adapter.open_pool_connection do |pooled|
          run_real_on(pooled, adapter, options) { yield }
        end
      end
    rescue ex : DB::Error
      handle_transaction_error(adapter, ex)
    rescue ex : PreservedIOError
      raise ex.original
    end

    # Commit callbacks run after the transaction leaves the fiber stack. Run
    # them outside the database-error rescue so their exceptions are preserved.
    outcome[0].each(&.call)
    outcome[1]
  end

  private def self.run_real_on(conn : DB::Connection, adapter : Grant::Adapter::Base, options : Options, & : -> T) : {Array(Proc(Nil)), T?} forall T
    if options.lazy_begin
      state = TransactionState.new(conn, options, adapter)
      state.defer_begin!
      fiber_stack.push(state)
    else
      execute_begin(conn, adapter, options)
      state = TransactionState.new(conn, options, adapter)
      fiber_stack.push(state)
      publish_transaction_start(state, nil)
    end
    value : T? = nil

    begin
      begin
        value = yield
      rescue ex : IO::Error
        raise PreservedIOError.new(ex)
      end
      # A deferred BEGIN that never went out means no statement ran: there is
      # nothing to commit.
      execute_control(conn, adapter, "COMMIT") unless state.begin_pending?
    rescue ex : Rollback
      return {abort_real(state), nil}
    rescue ex
      abort_real(state).each(&.call)
      raise ex
    end

    {finalize_commit(state), value}
  end

  # Issues ROLLBACK and settles the state. The state leaves the stack even if
  # ROLLBACK itself fails. Returns the rollback callbacks to run.
  private def self.abort_real(state : TransactionState) : Array(Proc(Nil))
    begin
      execute_control(state.raw_connection, state.adapter, "ROLLBACK") unless state.begin_pending?
    rescue ex
      finalize_rollback(state).each(&.call)
      raise ex
    end
    finalize_rollback(state)
  end

  private def self.leave_stack(state : TransactionState) : Nil
    stack = fiber_stack
    stack.delete(state)
    clear_fiber_stack if stack.empty?
    state.close
  end

  # *savepoint_name* is `nil` for a real transaction.
  private def self.publish_transaction_start(state : TransactionState, savepoint_name : String?) : Nil
    Grant::Notifications.instrument(Grant::Events::TransactionStart) do
      Grant::Events::TransactionStart.new(state.adapter.name, state.options, savepoint_name)
    end
  end

  private def self.publish_transaction_end(state : TransactionState, outcome : Grant::Events::TransactionOutcome, started_at : Time::Instant = state.started_at, savepoint_name : String? = nil) : Nil
    Grant::Notifications.instrument(Grant::Events::Transaction) do
      Grant::Events::Transaction.new(state.adapter.name, outcome, Time.instant - started_at, state.options, savepoint_name)
    end
  end

  private def self.finalize_rollback(state : TransactionState) : Array(Proc(Nil))
    pending = state.begin_pending?
    leave_stack(state)
    publish_transaction_end(state, Grant::Events::TransactionOutcome::Rollback) unless pending
    restore_transaction_records(state)
    state.pending_callbacks.map(&.[:on_rollback])
  end

  # A transaction committed durably on its own connection (true even for an
  # independent transaction nested inside another), so its after_commit
  # callbacks fire now. after_all blocks wait for the outermost commit.
  private def self.finalize_commit(state : TransactionState) : Array(Proc(Nil))
    pending = state.begin_pending?
    leave_stack(state)
    publish_transaction_end(state, Grant::Events::TransactionOutcome::Commit) unless pending
    state.list_of_record_rollback_actions.clear
    callbacks = state.pending_callbacks.map(&.[:on_commit])
    if parent = current_state?
      parent.after_all_commit_callbacks.concat(state.after_all_commit_callbacks)
    else
      callbacks.concat(state.after_all_commit_callbacks)
    end
    callbacks
  end

  # crystal-mysql's prepared-statement protocol does not implement transaction
  # control commands. Route those statements over COM_QUERY for MySQL; the
  # other adapters accept them through the normal DB execution path.
  private def self.execute_control(conn : DB::Connection, adapter : Grant::Adapter::Base, statement : String) : Nil
    Grant::Logs::Transaction.debug { statement }
    if adapter.mysql?
      conn.unprepared.exec(statement)
    else
      conn.exec(statement)
    end
  rescue ex : ::Exception
    raise adapter.translate_exception(ex, statement)
  ensure
    # BEGIN, COMMIT, ROLLBACK and savepoints change what other connections see.
    Grant::QueryCache.invalidate!
  end

  # Sends the `BEGIN` a lazy transaction held back, the moment a statement is
  # about to run on its connection.
  #
  # :nodoc:
  def self.send_deferred_begin(state : TransactionState) : Nil
    return unless state.begin_pending?

    # Cleared first: the statements below ask for the connection themselves.
    state.begin_pending = false
    begin
      execute_begin(state.raw_connection, state.adapter, state.options)
    rescue ex
      state.begin_pending = true
      state.begin_failed = true
      raise ex
    end
    publish_transaction_start(state, nil)
  end

  private def self.execute_begin(conn : DB::Connection, adapter : Grant::Adapter::Base, options : Options) : Nil
    begin_statements(adapter, options).each { |statement| execute_control(conn, adapter, statement) }
  end

  # The statements that open a real transaction with *options*, in the order
  # they are sent. MySQL needs `SET TRANSACTION ISOLATION LEVEL` before
  # `START TRANSACTION` (issued after, it would apply to the next transaction).
  def self.begin_statements(adapter : Grant::Adapter::Base, options : Options) : Array(String)
    if adapter.mysql?
      statements = [] of String
      if isolation = options.isolation
        statements << "SET TRANSACTION ISOLATION LEVEL #{isolation.to_sql}"
      end
      statements << (options.readonly ? "START TRANSACTION READ ONLY" : "START TRANSACTION")
      statements
    elsif adapter.postgres?
      parts = ["BEGIN"]
      if isolation = options.isolation
        parts << "ISOLATION LEVEL #{isolation.to_sql}"
      end
      parts << (options.readonly ? "READ ONLY" : "READ WRITE")
      [parts.join(" ")]
    elsif adapter.sqlite?
      case options.isolation
      when nil
        ["BEGIN"]
      when .serializable?
        ["BEGIN EXCLUSIVE"]
      when .read_uncommitted?
        ["BEGIN DEFERRED"]
      else
        ["BEGIN IMMEDIATE"]
      end
    else
      ["BEGIN"]
    end
  end

  # Re-raises *ex* as the matching `Grant::ErrorBase` when *adapter*
  # recognizes it, and unchanged otherwise.
  private def self.handle_transaction_error(adapter : Grant::Adapter::Base, ex : DB::Error) : NoReturn
    raise adapter.translate_exception(ex)
  end

  # Opens a transaction that stays open until `Handle#commit` / `#rollback`.
  # On an adapter with no open transaction this begins a real transaction on a
  # checked-out pool connection (held until settled); when one is already open
  # on the adapter it opens a savepoint and returns a nested handle.
  def self.begin_manual(adapter : Grant::Adapter::Base, options : Options) : Handle
    if state = current_state_for?(adapter)
      raise Grant::TransactionIsolationError.new if options.isolation
      name = state.next_savepoint_name
      marks = savepoint_marks(state)
      execute_control(state.connection, adapter, "SAVEPOINT #{name}")
      publish_transaction_start(state, name)
      handle = Handle.new(state, SavepointMarker.new(name, marks))
      state.manual_savepoints << handle
      return handle
    end

    owned = false
    conn = Grant::SchemaTenant.current_connection?(adapter) || adapter.pinned_connection?
    unless conn
      conn = adapter.database.checkout
      owned = true
    end

    begin
      execute_begin(conn, adapter, options)
    rescue ex
      conn.release if owned
      raise ex
    end

    new_state = TransactionState.new(conn, options, adapter)
    new_state.manual = true
    new_state.owns_connection = owned
    fiber_stack.push(new_state)
    publish_transaction_start(new_state, nil)
    new_state.handle
  end

  # :nodoc:
  def self.commit_manual(handle : Handle) : Nil
    state = handle.state
    raise NotOpenError.new unless state && handle.open?

    if savepoint = handle.savepoint?
      execute_control(state.connection, state.adapter, "RELEASE SAVEPOINT #{savepoint.name}")
      handle.settle
      state.manual_savepoints.delete(handle)
      publish_transaction_end(state, Grant::Events::TransactionOutcome::Commit, savepoint.started_at, savepoint.name)
      take_released_savepoint_callbacks(state, savepoint.marks).each(&.call) unless state.joinable?
      return
    end

    raise NotOpenError.new("Transaction was not opened with begin_transaction") unless state.manual?
    callbacks = begin
      execute_control(state.connection, state.adapter, "COMMIT")
      finalize_commit(state)
    rescue ex
      abort_real(state).each(&.call) if state.open?
      raise ex
    ensure
      release_manual(state)
    end
    callbacks.each(&.call)
  end

  # :nodoc:
  def self.rollback_manual(handle : Handle) : Nil
    state = handle.state
    raise NotOpenError.new unless state && handle.open?

    if savepoint = handle.savepoint?
      rollback_to_savepoint(state, savepoint.name, savepoint.marks)
      handle.settle
      state.manual_savepoints.delete(handle)
      publish_transaction_end(state, Grant::Events::TransactionOutcome::Rollback, savepoint.started_at, savepoint.name)
      return
    end

    raise NotOpenError.new("Transaction was not opened with begin_transaction") unless state.manual?
    callbacks = begin
      abort_real(state)
    ensure
      release_manual(state)
    end
    callbacks.each(&.call)
  end

  private def self.release_manual(state : TransactionState) : Nil
    state.manual_savepoints.each(&.settle)
    state.manual_savepoints.clear
    state.connection.release if state.owns_connection?
  end

  # Runs *block* inside a named savepoint of the open transaction on *adapter*.
  # Raises `NotOpenError` when none is open.
  def self.with_savepoint(adapter : Grant::Adapter::Base, name : String?, & : -> T) : T? forall T
    state = current_state_for?(adapter)
    raise NotOpenError.new("Savepoints require an open transaction") unless state
    if name && !(name =~ SAVEPOINT_NAME_PATTERN)
      raise InvalidSavepointNameError.new("Invalid savepoint name: #{name.inspect}")
    end
    run_savepoint(state, true, name) { yield }
  end

  module ClassMethods
    # Runs *block* inside a database transaction with default options and
    # returns the block's value (`nil` if the block raised `Rollback`). Every
    # `save`/`update`/`destroy` performed in the block is committed atomically
    # when the block returns; any uncaught exception (or
    # `Grant::Transaction::Rollback`) rolls the whole thing back.
    #
    # Called inside an open transaction, a plain block **joins** it (no SAVEPOINT
    # round trip); `Rollback` in a joined block is swallowed without undoing
    # anything. Use `requires_new: true` for a savepoint.
    #
    # ```
    # order = Order.transaction do
    #   Order.create!(total: 42.0)
    # end # => the created Order (Order? type)
    # ```
    def transaction(& : -> T) : T? forall T
      transaction(Transaction::Options.new) { yield }
    end

    # Runs *block* inside a transaction configured by *options* (a
    # `Transaction::Options`). Returns the block's value. The writer connection
    # is always used, whatever read role is active.
    #
    # ```
    # opts = Grant::Transaction::Options.new(readonly: true)
    # User.transaction(opts) { User.find!(1) }
    # ```
    def transaction(options : Transaction::Options, & : -> T) : T? forall T
      Grant::Transaction.run(transaction_adapter, options) { yield }
    end

    # The adapter a transaction on this model opens on. Always the writer: the
    # read/write splitter keeps every statement in an open transaction on it
    # (see `should_use_reader?`). `Grant::Sharding::Model` overrides it to use
    # the active shard's connection.
    #
    # :nodoc:
    def transaction_adapter : Grant::Adapter::Base
      resolve_adapter_for_role(Grant.settings.writing_role)
    end

    # Runs *block* inside a transaction, building the options from the given
    # keyword arguments. Returns the block's value.
    #
    # - *isolation* — an `IsolationLevel` (only for the outermost or an
    #   independent transaction; nested use raises `TransactionIsolationError`).
    # - *readonly* — open a read-only transaction; writes raise `ReadOnlyError`.
    # - *requires_new* — open a SAVEPOINT when already inside a transaction.
    # - *joinable* — `false` makes plain nested blocks open savepoints.
    # - *independent* — open a separate, separately committing transaction on a
    #   second pooled connection (holds two connections; can deadlock against
    #   rows the outer transaction holds).
    #
    # ```
    # User.transaction(isolation: :serializable) do
    #   account.update!(balance: account.balance - 100)
    # end
    #
    # User.transaction do
    #   outer.save!
    #   User.transaction(requires_new: true) { inner.save! } # SAVEPOINT
    # end
    # ```
    def transaction(isolation : IsolationLevel? = nil, readonly : Bool = false, requires_new : Bool = false, joinable : Bool = true, independent : Bool = false, & : -> T) : T? forall T
      options = Transaction::Options.new(
        isolation: isolation,
        readonly: readonly,
        requires_new: requires_new,
        joinable: joinable,
        independent: independent
      )
      transaction(options) { yield }
    end

    # Returns `true` when the current fiber has at least one explicit
    # transaction open, `false` otherwise.
    #
    # ```
    # User.transaction_open?                      # => false
    # User.transaction { User.transaction_open? } # => true (inside the block)
    # ```
    def transaction_open? : Bool
      Grant::Transaction.in_explicit_transaction?
    end

    # Returns a `Transaction::Handle` for the innermost open transaction. When
    # none is open it is a null handle (`open?` is `false`, `after_commit` runs
    # immediately).
    #
    # ```
    # User.transaction do
    #   User.current_transaction.after_commit { puts "committed" }
    # end
    # ```
    def current_transaction : Transaction::Handle
      Grant::Transaction.current_handle
    end

    # Runs *block* after the outermost transaction commits, or immediately when
    # none is open. Dropped on rollback.
    def after_all_transactions_commit(&block : -> Nil) : Nil
      Grant::Transaction.after_all_transactions_commit(&block)
    end
  end

  # Instance-level convenience that delegates to the class-level `transaction`
  # with default options, so you can write `user.transaction { ... }`. Returns
  # the block's value. The transaction is still scoped to the model class's
  # connection, not to this single record.
  #
  # ```
  # user.transaction do
  #   user.save!
  #   user.posts.first.destroy!
  # end
  # ```
  def transaction(& : -> T) : T? forall T
    self.class.transaction { yield }
  end

  # Instance-level convenience that delegates to the class-level
  # `transaction(options)`. Returns the block's value.
  #
  # ```
  # user.transaction(Grant::Transaction::Options.new(requires_new: true)) do
  #   user.save!
  # end
  # ```
  def transaction(options : Transaction::Options, & : -> T) : T? forall T
    self.class.transaction(options) { yield }
  end
end
