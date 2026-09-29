# Transaction-aware commit/rollback callbacks (ActiveRecord-compatible).
#
# The `after_commit`, `after_rollback`, and the per-operation
# `after_create_commit` / `after_update_commit` / `after_destroy_commit` /
# `after_save_commit` hooks
# are registered with the same callback macros as the rest of the lifecycle
# (see `Grant::Callbacks`), but they fire only when the surrounding transaction
# **durably settles**, not at the moment the row is written:
#
# - Inside an explicit `Model.transaction { ... }` (or `Grant::Transaction`)
#   block, commit callbacks are deferred and run when that transaction's real
#   `COMMIT` executes; `after_rollback` runs if it rolls back instead.
# - With no explicit transaction open, a save/destroy is its own implicit
#   single-statement transaction, so the callbacks fire immediately after it
#   succeeds.
#
# This is the right place to trigger side effects that must not happen until the
# data is truly persisted — enqueueing a background job, sending an email,
# busting a cache — because they won't fire for work that a later rollback
# discards.
#
# ```
# class Order < Grant::Base
#   column id : Int64, primary: true
#   column total : Float64 = 0.0
#
#   after_create_commit :enqueue_fulfillment
#   after_commit :bust_cache
#   after_rollback :log_failure
#
#   private def enqueue_fulfillment
#     # runs only once the INSERT has committed for good
#   end
#
#   private def bust_cache; end
#
#   private def log_failure; end
# end
#
# # Deferred: callbacks fire at COMMIT, not at save.
# Order.transaction do
#   order = Order.create(total: 42.0)
#   # ...more work; if this raised, after_rollback would fire instead
# end # => after_create_commit + after_commit fire here
# ```
#
# ## `after_save_commit`
#
# Fires once after a create *or* an update commits. It fires once even when
# `after_create_commit` or `after_update_commit` is registered as well.
#
# ## `on:`
#
# `after_commit` and `after_rollback` take `on:` (a Symbol or an Array of
# `:create`, `:update`, `:destroy`) to restrict them to those operations:
#
# ```
# after_commit :notify, on: [:create, :update]
# after_rollback :log_failed_insert, on: :create
# ```
#
# ## Deduplication
#
# When one record is saved several times inside a single transaction, each
# commit callback still runs once per record when that transaction settles
# (ActiveRecord behavior). The operations seen along the way are merged, so
# `on: :create` still matches a record that was created and then updated.
module Grant::CommitCallbacks
  # Bit for each commit callback, in dispatch order. Callbacks are queued and
  # merged as bits so repeated saves never allocate or duplicate entries.
  COMMIT_CALLBACK_BITS = {
    after_create_commit:  1_u8,
    after_update_commit:  2_u8,
    after_destroy_commit: 4_u8,
    after_save_commit:    8_u8,
    after_commit:         16_u8,
  }

  ACTION_CREATE  = 1_u8
  ACTION_UPDATE  = 2_u8
  ACTION_DESTROY = 4_u8

  # The commit callbacks and operations one record has accumulated inside one
  # open transaction, registered with that transaction exactly once.
  # :nodoc:
  class Deferred
    getter owner_id : UInt64
    getter state : Grant::Transaction::TransactionState
    property commit_bits : UInt8
    property action_bits : UInt8
    property? settled : Bool = false

    def initialize(@owner_id : UInt64, @state : Grant::Transaction::TransactionState, @commit_bits : UInt8, @action_bits : UInt8)
    end
  end

  macro included
    # Per-instance queue of pending commit callbacks.
    # Declared nilable (with lazy initialization in `_pending_commit_callbacks`
    # below) rather than carrying a default value so that `YAML::Serializable` /
    # `JSON::Serializable`'s auto-generated deserialization initializer — included
    # on the abstract `Grant::Base` — does not report it as uninitialized for
    # `Grant::Base+`. See issues #39/#41.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_pending_commit_callbacks : Array(Symbol)?

    # The operations (`ACTION_*` bits) of the commit or rollback callbacks
    # currently being dispatched; read by `on:` conditions.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_commit_action_bits : UInt8?

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_deferred_commit : Grant::CommitCallbacks::Deferred?

    protected def _pending_commit_callbacks : Array(Symbol)
      @_pending_commit_callbacks ||= [] of Symbol
    end
  end

  # Queue a callback symbol for this instance (used internally after save/destroy).
  # A queued create or update commit also queues `after_save_commit`.
  private def queue_commit_callback(callback_name : Symbol)
    _pending_commit_callbacks << callback_name
    if callback_name == :after_create_commit || callback_name == :after_update_commit
      _pending_commit_callbacks << :after_save_commit
    end
  end

  # Whether the commit or rollback callback being dispatched belongs to one of
  # *actions* (`:create`, `:update`, `:destroy`). Used by `on:` conditions.
  #
  # :nodoc:
  def __commit_on?(*actions : Symbol) : Bool
    # Called outside a dispatch (a direct `after_rollback` after a failed
    # save): infer the operation from the record's state.
    bits = @_commit_action_bits || (new_record? ? ACTION_CREATE : ACTION_UPDATE)
    actions.each do |action|
      return true if (bits & Grant::CommitCallbacks.action_bit(action)) != 0
    end
    false
  end

  # :nodoc:
  def self.action_bit(action : Symbol) : UInt8
    case action
    when :create  then ACTION_CREATE
    when :update  then ACTION_UPDATE
    when :destroy then ACTION_DESTROY
    else
      raise ArgumentError.new("Unknown commit callback action #{action.inspect}; use :create, :update or :destroy")
    end
  end

  # Called immediately after a successful save/destroy.
  #
  # If the current fiber is inside an explicit Grant::Transaction block the
  # callbacks are deferred: a closure pair (on_commit / on_rollback) is
  # registered on the innermost open transaction's state and fires when that
  # transaction's real COMMIT or ROLLBACK executes.  Savepoints share the
  # enclosing transaction's state; requires_new transactions fire their own
  # callbacks at their own commit (which is independently durable). Further
  # saves of the same record in the same transaction merge into that one
  # registration, so each callback runs once per record.
  #
  # If there is NO explicit transaction open (implicit single-operation
  # transaction) the callbacks are fired immediately, preserving the
  # pre-existing behaviour.
  private def run_commit_callbacks
    return if _pending_commit_callbacks.empty?

    commit_bits = 0_u8
    action_bits = 0_u8
    _pending_commit_callbacks.each do |callback_name|
      case callback_name
      when :after_create_commit  then action_bits |= ACTION_CREATE
      when :after_update_commit  then action_bits |= ACTION_UPDATE
      when :after_destroy_commit then action_bits |= ACTION_DESTROY
      end
      bit = COMMIT_CALLBACK_BITS[callback_name]?
      commit_bits |= bit if bit
    end
    _pending_commit_callbacks.clear
    # A bare `after_commit` (touch) is an update.
    action_bits = ACTION_UPDATE if action_bits == 0_u8

    state = Grant::Transaction.current_state?
    if state && Grant::Transaction.in_explicit_transaction?
      if (existing = @_deferred_commit) && existing.owner_id == object_id && existing.state.same?(state) && !existing.settled?
        existing.commit_bits |= commit_bits
        existing.action_bits |= action_bits
        return
      end

      deferred = Deferred.new(object_id, state, commit_bits, action_bits)
      @_deferred_commit = deferred

      on_commit = Proc(Nil).new do
        deferred.settled = true
        @_deferred_commit = nil if @_deferred_commit.same?(deferred)
        dispatch_commit_callbacks(deferred.commit_bits, deferred.action_bits)
      end

      on_rollback = Proc(Nil).new do
        deferred.settled = true
        @_deferred_commit = nil if @_deferred_commit.same?(deferred)
        dispatch_rollback_callbacks(deferred.action_bits)
      end

      Grant::Transaction.enqueue_pending_callback(on_commit, on_rollback)
    else
      # No explicit transaction — fire immediately (implicit single-row tx).
      dispatch_commit_callbacks(commit_bits, action_bits)
    end
  end

  # Runs the commit callbacks whose bits are set, in the fixed order of
  # `COMMIT_CALLBACK_BITS`, exposing *action_bits* to `on:` conditions.
  private def dispatch_commit_callbacks(commit_bits : UInt8, action_bits : UInt8) : Nil
    @_commit_action_bits = action_bits
    begin
      after_create_commit if (commit_bits & 1_u8) != 0 && responds_to?(:after_create_commit)
      after_update_commit if (commit_bits & 2_u8) != 0 && responds_to?(:after_update_commit)
      after_destroy_commit if (commit_bits & 4_u8) != 0 && responds_to?(:after_destroy_commit)
      after_save_commit if (commit_bits & 8_u8) != 0 && responds_to?(:after_save_commit)
      after_commit if (commit_bits & 16_u8) != 0 && responds_to?(:after_commit)
    ensure
      @_commit_action_bits = nil
    end
  end

  private def dispatch_rollback_callbacks(action_bits : UInt8) : Nil
    @_commit_action_bits = action_bits
    begin
      after_rollback if responds_to?(:after_rollback)
    ensure
      @_commit_action_bits = nil
    end
  end

  # Clears pending instance-level queued callbacks (used when an operation
  # fails before run_commit_callbacks is reached).
  private def clear_commit_callbacks
    _pending_commit_callbacks.clear
  end

  # Called when an operation fails (DB::Error / Callbacks::Abort) so that the
  # implicit per-save rollback is signalled via after_rollback.  When inside
  # an explicit transaction this is a no-op: the transaction's own rollback
  # path will fire after_rollback for all pending instances at once.
  private def run_rollback_callbacks
    clear_commit_callbacks
    unless Grant::Transaction.in_explicit_transaction?
      dispatch_rollback_callbacks(ACTION_DESTROY)
    end
  end
end
