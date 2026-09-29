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
# (ActiveRecord behavior). The operations seen along the way resolve to one:
# a record destroyed in the transaction is a destroy, one created in it (and
# perhaps updated after) is a create, and anything else is an update. So a
# record created then updated gets `after_create_commit`, not
# `after_update_commit`, and `on: :create` matches it.
# Work undone by a rolled back savepoint is left out of that merge: it gets
# `after_rollback` when the savepoint rolls back, as before.
module Grant::CommitCallbacks
  # Bit for each commit callback, in dispatch order. Callbacks are queued and
  # merged as bits so repeated saves never duplicate entries.
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

  # One save's or destroy's share of a record's commit callbacks: the callback
  # and operation bits it queued, and whether a savepoint rollback (or an early
  # savepoint release) has already settled it on its own.
  # :nodoc:
  class Contribution
    getter commit_bits : UInt8
    getter action_bits : UInt8
    property? live : Bool = true

    def initialize(@commit_bits : UInt8, @action_bits : UInt8)
    end
  end

  # The commit callbacks one record has accumulated inside one open
  # transaction. The first contribution's callback pair (the lead) dispatches
  # the merged bits of every contribution still live when the transaction
  # settles, so each callback runs once per record.
  # :nodoc:
  class Deferred
    getter state : Grant::Transaction::TransactionState
    getter list_of_contributions : Array(Contribution)
    property? settled : Bool = false

    def initialize(@state : Grant::Transaction::TransactionState, lead : Contribution)
      @list_of_contributions = [lead]
    end

    def live_commit_bits : UInt8
      list_of_contributions.reduce(0_u8) { |bits, contribution| contribution.live? ? bits | contribution.commit_bits : bits }
    end

    def live_action_bits : UInt8
      list_of_contributions.reduce(0_u8) { |bits, contribution| contribution.live? ? bits | contribution.action_bits : bits }
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
  # the operations in *action_mask* (`ACTION_*` bits, folded from `on:` at
  # compile time).
  #
  # :nodoc:
  def __commit_on?(action_mask : UInt8) : Bool
    # Called outside a dispatch (a direct `record.after_rollback`): infer the
    # operation from the record's state.
    bits = @_commit_action_bits || (new_record? ? ACTION_CREATE : ACTION_UPDATE)
    (bits & action_mask) != 0
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
      contribution = Contribution.new(commit_bits, action_bits)
      lead = @_deferred_commit
      if lead && lead.state.same?(state) && !lead.settled?
        lead.list_of_contributions << contribution
        Grant::Transaction.enqueue_pending_callback(
          Proc(Nil).new { settle_commit_contribution(lead, contribution) },
          Proc(Nil).new { settle_rollback_contribution(lead, contribution) }
        )
      else
        deferred = Deferred.new(state, contribution)
        @_deferred_commit = deferred
        Grant::Transaction.enqueue_pending_callback(
          Proc(Nil).new { settle_deferred_commit(deferred) },
          Proc(Nil).new { settle_deferred_rollback(deferred) }
        )
      end
    else
      # No explicit transaction — fire immediately (implicit single-row tx).
      dispatch_commit_callbacks(commit_bits, action_bits)
    end
  end

  # The lead pair's commit: the transaction committed, so dispatch every
  # contribution a savepoint rollback has not already settled.
  private def settle_deferred_commit(deferred : Deferred) : Nil
    return if deferred.settled?
    deferred.settled = true
    @_deferred_commit = nil if @_deferred_commit.same?(deferred)
    dispatch_commit_callbacks(deferred.live_commit_bits, deferred.live_action_bits)
  end

  # The lead pair's rollback: the transaction (or the savepoint holding the
  # first save) rolled back, taking every later contribution with it.
  private def settle_deferred_rollback(deferred : Deferred) : Nil
    return if deferred.settled?
    deferred.settled = true
    @_deferred_commit = nil if @_deferred_commit.same?(deferred)
    dispatch_rollback_callbacks(deferred.live_action_bits)
  end

  # A later contribution's commit. At the real COMMIT the lead has already
  # settled everything, so this does nothing; it fires on its own only when a
  # savepoint under a non-joinable transaction is released early.
  private def settle_commit_contribution(deferred : Deferred, contribution : Contribution) : Nil
    return if deferred.settled? || !contribution.live?
    contribution.live = false
    dispatch_commit_callbacks(contribution.commit_bits, contribution.action_bits)
  end

  # A later contribution's rollback. At the real ROLLBACK the lead has already
  # settled everything; otherwise a savepoint holding this save rolled back,
  # so it gets `after_rollback` now and drops out of the lead's commit.
  private def settle_rollback_contribution(deferred : Deferred, contribution : Contribution) : Nil
    return if deferred.settled? || !contribution.live?
    contribution.live = false
    dispatch_rollback_callbacks(contribution.action_bits)
  end

  # Runs the commit callbacks whose bits are set, in the fixed order of
  # `COMMIT_CALLBACK_BITS`, for the one operation the merged *action_bits*
  # resolve to (see `resolve_commit_action`), and exposes that operation to
  # `on:` conditions.
  private def dispatch_commit_callbacks(commit_bits : UInt8, action_bits : UInt8) : Nil
    action = resolve_commit_action(action_bits)
    @_commit_action_bits = action
    begin
      if action == ACTION_CREATE
        after_create_commit if (commit_bits & COMMIT_CALLBACK_BITS[:after_create_commit]) != 0 && responds_to?(:after_create_commit)
      end
      if action == ACTION_UPDATE
        after_update_commit if (commit_bits & COMMIT_CALLBACK_BITS[:after_update_commit]) != 0 && responds_to?(:after_update_commit)
      end
      if action == ACTION_DESTROY
        after_destroy_commit if (commit_bits & COMMIT_CALLBACK_BITS[:after_destroy_commit]) != 0 && responds_to?(:after_destroy_commit)
      else
        after_save_commit if (commit_bits & COMMIT_CALLBACK_BITS[:after_save_commit]) != 0 && responds_to?(:after_save_commit)
      end
      after_commit if (commit_bits & COMMIT_CALLBACK_BITS[:after_commit]) != 0 && responds_to?(:after_commit)
    ensure
      @_commit_action_bits = nil
    end
  end

  private def dispatch_rollback_callbacks(action_bits : UInt8) : Nil
    @_commit_action_bits = resolve_commit_action(action_bits)
    begin
      after_rollback if responds_to?(:after_rollback)
    ensure
      @_commit_action_bits = nil
    end
  end

  # Resolves the operations one record went through in a transaction to the
  # single one its commit and rollback callbacks belong to, as ActiveRecord
  # does: a destroyed record is a destroy, a record created in the
  # transaction (then perhaps updated) is a create, anything else an update.
  private def resolve_commit_action(action_bits : UInt8) : UInt8
    if (action_bits & ACTION_DESTROY) != 0
      ACTION_DESTROY
    elsif (action_bits & ACTION_CREATE) != 0
      ACTION_CREATE
    else
      ACTION_UPDATE
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
