# Transaction-aware commit/rollback callbacks (ActiveRecord-compatible).
#
# The `after_commit`, `after_rollback`, and the per-operation
# `after_create_commit` / `after_update_commit` / `after_destroy_commit` hooks
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
module Grant::CommitCallbacks
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

    protected def _pending_commit_callbacks : Array(Symbol)
      @_pending_commit_callbacks ||= [] of Symbol
    end
  end

  # Queue a callback symbol for this instance (used internally after save/destroy).
  private def queue_commit_callback(callback_name : Symbol)
    _pending_commit_callbacks << callback_name
  end

  # Called immediately after a successful save/destroy.
  #
  # If the current fiber is inside an explicit Grant::Transaction block the
  # callbacks are deferred: a closure pair (on_commit / on_rollback) is
  # registered on the innermost open transaction's state and fires when that
  # transaction's real COMMIT or ROLLBACK executes.  Savepoints share the
  # enclosing transaction's state; requires_new transactions fire their own
  # callbacks at their own commit (which is independently durable).
  #
  # If there is NO explicit transaction open (implicit single-operation
  # transaction) the callbacks are fired immediately, preserving the
  # pre-existing behaviour.
  private def run_commit_callbacks
    return if _pending_commit_callbacks.empty?

    callbacks = _pending_commit_callbacks.dup
    _pending_commit_callbacks.clear

    if Grant::Transaction.in_explicit_transaction?
      # Capture the callback list by value in the closures.
      on_commit = Proc(Nil).new do
        callbacks.each do |callback_name|
          case callback_name
          when :after_commit
            after_commit if responds_to?(:after_commit)
          when :after_create_commit
            after_create_commit if responds_to?(:after_create_commit)
          when :after_update_commit
            after_update_commit if responds_to?(:after_update_commit)
          when :after_destroy_commit
            after_destroy_commit if responds_to?(:after_destroy_commit)
          end
        end
      end

      on_rollback = Proc(Nil).new do
        after_rollback if responds_to?(:after_rollback)
      end

      Grant::Transaction.enqueue_pending_callback(on_commit, on_rollback)
    else
      # No explicit transaction — fire immediately (implicit single-row tx).
      callbacks.each do |callback_name|
        case callback_name
        when :after_commit
          after_commit if responds_to?(:after_commit)
        when :after_create_commit
          after_create_commit if responds_to?(:after_create_commit)
        when :after_update_commit
          after_update_commit if responds_to?(:after_update_commit)
        when :after_destroy_commit
          after_destroy_commit if responds_to?(:after_destroy_commit)
        end
      end
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
      after_rollback if responds_to?(:after_rollback)
    end
  end
end
