require "./validation"

# Lifecycle callbacks for Grant models (ActiveRecord-compatible).
#
# Including this module (done automatically by `Grant::Base`) gives every model
# a family of class-macro hooks that run around the persistence lifecycle. Each
# macro registers a callback that fires at the matching point of `save`,
# `create`, `update`, `destroy`, validation, or after a transaction settles.
#
# ## Available hooks
#
# Registered via the like-named macro (`after_save :method_name`,
# `before_create { ... }`, etc.). Order below is roughly the order they fire:
#
# - `after_initialize` — after `Model.new`
# - `after_find` — after a row is loaded from the database
# - `before_validation` / `after_validation` — wrap `valid?`
# - `before_save` / `after_save` — wrap any persistence (create *or* update)
# - `before_create` / `after_create` — only when inserting a new row
# - `before_update` / `after_update` — only when updating an existing row
# - `before_destroy` / `after_destroy` — wrap `destroy`
# - `after_touch` — after `touch`
# - `after_commit` / `after_rollback` (both take `on: [:create, :update,
#   :destroy]`) and the per-operation `after_create_commit` /
#   `after_update_commit` / `after_destroy_commit` / `after_save_commit` —
#   fire once the surrounding transaction durably commits or rolls back (see
#   `Grant::CommitCallbacks`)
#
# `around_validation`, `around_save`, `around_create`, `around_update`, and
# `around_destroy` wrap the operation and **must** call their yielded
# continuation to let it proceed (see the `around_*` macro docs below).
#
# ## Forms
#
# Each callback macro accepts a method name (a Symbol), a block, or several of
# either. The block runs in instance context, so it can read and mutate `self`'s
# columns directly.
#
# ```
# class Article < Grant::Base
#   column id : Int64, primary: true
#   column title : String?
#   column slug : String?
#   column published : Bool = false
#
#   before_save :generate_slug               # method form
#   before_create { self.published = false } # block form
#
#   private def generate_slug
#     self.slug = title.to_s.downcase.gsub(/\s+/, "-")
#   end
# end
# ```
#
# ## `:if` / `:unless` conditions
#
# Every callback macro takes `if:` and/or `unless:`, each either a Symbol naming
# an instance method or a Proc/lambda that receives the record. The callback
# runs only when `if:` is truthy and `unless:` is falsy.
#
# ```
# class Order < Grant::Base
#   column id : Int64, primary: true
#   column total : Float64 = 0.0
#   column notified : Bool = false
#
#   after_create :send_receipt, if: :paid?
#   after_save :alert_finance, unless: ->(o : Order) { o.total < 1000 }
#
#   def paid? : Bool
#     total > 0
#   end
#
#   private def send_receipt
#     self.notified = true
#   end
#
#   private def alert_finance; end
# end
# ```
#
# Conditions may also be an Array (`if: [:paid?, ->(o : Order) { o.total > 0 }]`,
# every `if:` term must hold and no `unless:` term may). Validation callbacks
# additionally take `on:` (a context or an Array of contexts):
#
# ```
# before_validation :normalize_slug, on: [:create, :publish]
# ```
#
# ## `prepend: true`
#
# Every callback macro (around callbacks included) takes `prepend: true` to
# put its entries at the front of the class's own chain instead of the end,
# keeping their given order. Callbacks inherited from a parent class still run
# before the subclass's own chain.
#
# ```
# before_destroy :check_children, prepend: true
# ```
#
# ## Halting
#
# Call `abort!` inside a persistence callback to raise
# `Grant::Callbacks::Abort` and stop the operation. An abort from any save
# lifecycle callback through `after_save` rolls back the save transaction.
# Commit callbacks run after the transaction commits. An `around_*` callback
# halts simply by **not** calling its continuation.
#
# ```
# class Account < Grant::Base
#   column id : Int64, primary: true
#   column locked : Bool = false
#
#   before_destroy :guard_locked
#
#   private def guard_locked
#     abort!("cannot destroy a locked account") if locked
#   end
# end
# ```
module Grant::Callbacks
  # Raised by `abort!` to halt the current persistence operation from inside a
  # callback. Save operations roll back the write and report the failure.
  class Abort < Exception
  end

  CALLBACK_NAMES = %w(
    after_initialize after_find
    before_validation after_validation
    before_save after_save
    before_create after_create
    before_update after_update
    before_destroy after_destroy
    after_touch
    after_commit after_rollback
    after_create_commit after_update_commit after_destroy_commit after_save_commit
  )

  # Events `run_callbacks` accepts (each has a `before_`/`after_` chain and,
  # for some, an `around_` chain).
  CALLBACK_EVENTS = %w(initialize find validation save create update destroy touch)

  AROUND_CALLBACK_NAMES = %w(
    around_validation
    around_save
    around_create
    around_update
    around_destroy
  )

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_current_callback : String?

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_around_halted : Bool?

  macro included
    macro inherited
      disable_grant_docs? CALLBACKS = {
        {% for name in CALLBACK_NAMES %}
          {{name.id}}: [] of Nil,
        {% end %}
      }

      disable_grant_docs? AROUND_CALLBACKS = {
        {% for name in AROUND_CALLBACK_NAMES %}
          {{name.id}}: [] of Nil,
        {% end %}
      }

      {% for name in CALLBACK_NAMES %}
        disable_grant_docs? def {{name.id}}
          __{{name.id}}
        end
      {% end %}
    end
  end

  {% for name in CALLBACK_NAMES %}
    {% commit_on = (name == "after_commit" || name == "after_rollback") %}
    macro {{name.id}}(*callbacks, if condition = nil, unless unless_condition = nil, on on_context = nil, prepend prepend_first = false, &block)
      {% if name == "after_commit" || name == "after_rollback" %}
        \{% if on_context %}
          \{% for action in (on_context.is_a?(ArrayLiteral) ? on_context : [on_context]) %}
            \{% action.raise "`on:` accepts :create, :update or :destroy" unless action.is_a?(SymbolLiteral) && [:create, :update, :destroy].includes?(action) %}
          \{% end %}
        \{% end %}
      {% elsif !name.includes?("validation") %}
        \{% on_context.raise "`on:` is only supported on before_validation, after_validation, around_validation, after_commit and after_rollback" if on_context %}
      {% end %}
      \{% entries = [] of ASTNode %}
      \{% for callback in callbacks %}
        \{% if condition || unless_condition || on_context %}
          \{% entries << {callback: callback, if: condition, unless: unless_condition, on: on_context} %}
        \{% else %}
          \{% entries << callback %}
        \{% end %}
      \{% end %}
      \{% if block.is_a? Block %}
        \{% if condition || unless_condition || on_context %}
          \{% entries << {callback: block, if: condition, unless: unless_condition, on: on_context} %}
        \{% else %}
          \{% entries << block %}
        \{% end %}
      \{% end %}
      # `prepend: true` puts the entries at the front of this class's chain,
      # keeping their given order; otherwise they are appended.
      \{% if prepend_first %}
        \{% for entry_index in (0...entries.size) %}
          \{% entry = entries[entries.size - 1 - entry_index] %}
          \{% CALLBACKS[{{name}}].unshift(entry) %}
        \{% end %}
      \{% else %}
        \{% for entry in entries %}
          \{% CALLBACKS[{{name}}] << entry %}
        \{% end %}
      \{% end %}
    end

    macro __{{name.id}}
      @_current_callback = {{name}}
      \{% callbacks = [] of ASTNode %}
      \{% callback_classes = @type.ancestors + [@type] %}
      \{% for ancestor in callback_classes %}
        \{% if ancestor.class? && ancestor.has_constant?("CALLBACKS") %}
          \{% for callback_data in ancestor.constant("CALLBACKS")[{{name}}] %}
            \{% callbacks << callback_data %}
          \{% end %}
        \{% end %}
      \{% end %}
      \{% for callback_data in callbacks %}
        \{% if callback_data.is_a? NamedTupleLiteral %}
          \{% callback = callback_data[:callback] %}
          \{% condition = callback_data[:if] %}
          \{% unless_condition = callback_data[:unless] %}
          \{% on_context = callback_data[:on] %}
          # `if:`/`unless:` accept a Symbol (instance method name), a
          # Proc/lambda that receives the record, or an Array of them (all
          # `if:` terms must hold, no `unless:` term may). `on:` restricts a
          # validation callback to the running validation context(s). See
          # `Grant::Conditions.met?`.
          {% if commit_on %}
          # `on:` here names the operations (`:create`, `:update`, `:destroy`)
          # the commit/rollback belongs to; see `Grant::CommitCallbacks`.
          if Grant::Conditions.met?(nil, \{{condition}}, \{{unless_condition}}, nil) && \{% if on_context %}__commit_on?(\{{(on_context.is_a?(ArrayLiteral) ? on_context : [on_context]).splat}})\{% else %}true\{% end %}
          {% else %}
          if Grant::Conditions.met?(nil, \{{condition}}, \{{unless_condition}}, \{{on_context}})
          {% end %}
            \{% if callback.is_a? Block %}
              begin
                \{{callback.body}}
              end
            \{% else %}
              \{{callback.id}}
            \{% end %}
          end
        \{% elsif callback_data.is_a? Block %}
          begin
            \{{callback_data.body}}
          end
        \{% else %}
          \{{callback_data.id}}
        \{% end %}
      \{% end %}
    end
  {% end %}

  # Around callbacks wrap an operation and must call the provided proc
  # to continue execution. If the proc is not called, the operation
  # is halted (similar to `abort!`).
  #
  # Around callbacks can be defined with either a method name or a block:
  #
  # ```
  # # Method-based: method receives a Proc(Nil) and must call it
  # around_save :wrap_in_logging
  #
  # private def wrap_in_logging(block : Proc(Nil))
  #   puts "Starting..."
  #   block.call
  #   puts "Done!"
  # end
  #
  # # Block-based: block variable is available as a Proc(Nil)
  # around_save do |block|
  #   puts "Starting..."
  #   block.call
  #   puts "Done!"
  # end
  # ```
  {% for name in AROUND_CALLBACK_NAMES %}
    macro {{name.id}}(*callbacks, if condition = nil, unless unless_condition = nil, on on_context = nil, prepend prepend_first = false, &block)
      {% unless name.includes?("validation") %}
        \{% on_context.raise "`on:` is only supported on before_validation, after_validation and around_validation" if on_context %}
      {% end %}
      \{% entries = [] of ASTNode %}
      \{% for callback in callbacks %}
        \{% if condition || unless_condition || on_context %}
          \{% entries << {callback: callback, if: condition, unless: unless_condition, on: on_context} %}
        \{% else %}
          \{% entries << callback %}
        \{% end %}
      \{% end %}
      \{% if block.is_a? Block %}
        \{% if condition || unless_condition || on_context %}
          \{% entries << {callback: block, if: condition, unless: unless_condition, on: on_context} %}
        \{% else %}
          \{% entries << block %}
        \{% end %}
      \{% end %}
      \{% if prepend_first %}
        \{% for entry_index in (0...entries.size) %}
          \{% entry = entries[entries.size - 1 - entry_index] %}
          \{% AROUND_CALLBACKS[{{name}}].unshift(entry) %}
        \{% end %}
      \{% else %}
        \{% for entry in entries %}
          \{% AROUND_CALLBACKS[{{name}}] << entry %}
        \{% end %}
      \{% end %}
    end
  {% end %}

  # Generate the __run_around_* methods.
  #
  # Uses an array-based chain with compile-time computed indices to
  # avoid variable aliasing in macro for-loops (which would cause
  # infinite recursion with %var capture).
  {% for name in AROUND_CALLBACK_NAMES %}
    macro __run_{{name.id}}(&inner_block)
      @_current_callback = {{name}}
      @_around_halted = false

      \{% callbacks = [] of ASTNode %}
      \{% callback_classes = @type.ancestors + [@type] %}
      \{% for ancestor in callback_classes %}
        \{% if ancestor.class? && ancestor.has_constant?("AROUND_CALLBACKS") %}
          \{% for callback in ancestor.constant("AROUND_CALLBACKS")[{{name}}] %}
            \{% callbacks << callback %}
          \{% end %}
        \{% end %}
      \{% end %}
      \{% if callbacks.empty? %}
        # No around callbacks — just run the operation directly
        begin
          \{{inner_block.body}}
        end
      \{% else %}
        # Use an array to build the proc chain.
        # Index 0 = innermost (the actual operation).
        # Index N = outermost (first registered callback).
        # Each callback at index i calls chain[i-1].
        %chain = [] of Proc(Nil)

        # Index 0: the actual operation
        %chain << Proc(Nil).new do
          \{{inner_block.body}}
        end

        # Build from innermost to outermost.
        # Callbacks are [first_registered, ..., last_registered].
        # First registered should be outermost, so iterate in reverse.
        \{% for idx in (0...callbacks.size) %}
          \{% rev_idx = callbacks.size - 1 - idx %}
          \{% callback_data = callbacks[rev_idx] %}
          \{%
            # This callback's continuation is at index `idx` (0-based)
            # which is the previous entry in the chain array.
            prev_index = idx
          %}

          \{% if callback_data.is_a? NamedTupleLiteral %}
            \{% callback = callback_data[:callback] %}
            \{% condition = callback_data[:if] %}
            \{% unless_condition = callback_data[:unless] %}
            \{% on_context = callback_data[:on] %}

            # See `__{{name.id}}` above and `Grant::Conditions.met?`.
            if Grant::Conditions.met?(nil, \{{condition}}, \{{unless_condition}}, \{{on_context}})
              \{% if callback.is_a? Block %}
                %chain << Proc(Nil).new do
                  %called = false
                  block = Proc(Nil).new do
                    %called = true
                    %chain[\{{prev_index}}].call
                  end
                  \{{callback.body}}
                  unless %called
                    @_around_halted = true
                  end
                end
              \{% else %}
                %chain << Proc(Nil).new do
                  %called = false
                  %continuation = Proc(Nil).new do
                    %called = true
                    %chain[\{{prev_index}}].call
                  end
                  \{{callback.id}}(%continuation)
                  unless %called
                    @_around_halted = true
                  end
                end
              \{% end %}
            else
              # Condition not met — pass through to the previous chain entry
              %chain << %chain[\{{prev_index}}]
            end
          \{% elsif callback_data.is_a? Block %}
            %chain << Proc(Nil).new do
              %called = false
              block = Proc(Nil).new do
                %called = true
                %chain[\{{prev_index}}].call
              end
              \{{callback_data.body}}
              unless %called
                @_around_halted = true
              end
            end
          \{% else %}
            # Method-based callback
            %chain << Proc(Nil).new do
              %called = false
              %continuation = Proc(Nil).new do
                %called = true
                %chain[\{{prev_index}}].call
              end
              \{{callback_data.id}}(%continuation)
              unless %called
                @_around_halted = true
              end
            end
          \{% end %}
        \{% end %}

        # Execute the outermost callback (last entry in chain)
        %chain.last.call
      \{% end %}
    end
  {% end %}

  # Runs the callbacks of *event* (`:save`, `:create`, `:update`, `:destroy`,
  # `:validation`, `:touch`, `:initialize` or `:find`) around an optional
  # block, exactly as the persistence machinery does: `before_*` callbacks, the
  # block, then `after_*` callbacks, all wrapped in the `around_*` chain when
  # the event has one. It expands at compile time.
  #
  # Returns the block's value, or `nil` when an `around_*` callback halted by
  # not yielding (the block and the `after_*` callbacks then do not run). An
  # `abort!` raises `Grant::Callbacks::Abort` to the caller.
  #
  # ```
  # order.run_callbacks(:save) { order.write_audit_row } # => audit row or nil
  # ```
  #
  # With no block it just runs the chains and returns `true` (or `false` if
  # halted). When *event* is not a literal (a variable), it dispatches at
  # runtime through a `case` over the known events:
  #
  # ```
  # order.run_callbacks(event_name) # => Bool
  # ```
  macro run_callbacks(event, &block)
    {% if event.is_a?(SymbolLiteral) || event.is_a?(StringLiteral) %}
      {% ev = event.id.stringify %}
      {% has_before = Grant::Callbacks::CALLBACK_NAMES.includes?("before_" + ev) %}
      {% has_after = Grant::Callbacks::CALLBACK_NAMES.includes?("after_" + ev) %}
      {% has_around = Grant::Callbacks::AROUND_CALLBACK_NAMES.includes?("around_" + ev) %}
      {% event.raise "unknown callback event #{ev}; use one of #{Grant::Callbacks::CALLBACK_EVENTS.join(", ").id}" unless has_before || has_after || has_around %}
      {% if has_around %}
        %result = nil
        __run_around_{{ev.id}} do
          {% if has_before %}__before_{{ev.id}}{% end %}
          %result = {% if block %}{{block.body}}{% else %}true{% end %}
          {% if has_after %}__after_{{ev.id}} unless around_halted?{% end %}
        end
        around_halted? ? nil : %result
      {% else %}
        {% if has_before %}__before_{{ev.id}}{% end %}
        %result = {% if block %}{{block.body}}{% else %}true{% end %}
        {% if has_after %}__after_{{ev.id}}{% end %}
        %result
      {% end %}
    {% else %}
      {% block.raise "run_callbacks with a non-literal event does not take a block" if block %}
      run_callbacks_for({{event}})
    {% end %}
  end

  # Runtime form of `run_callbacks` for an event held in a variable. Returns
  # `false` when an `around_*` callback halted, `true` otherwise. Dispatch is
  # a compile-time expanded chain of Symbol comparisons, so nothing is allocated.
  def run_callbacks_for(event : Symbol) : Bool
    {% for ev in CALLBACK_EVENTS %}
      return !!run_callbacks(:{{ev.id}}) { true } if event == :{{ev.id}}
    {% end %}
    raise ArgumentError.new("Unknown callback event #{event.inspect}; use one of #{CALLBACK_EVENTS.join(", ")}")
  end

  # Returns `true` if the most recent `around_*` callback halted the operation
  # by failing to call its continuation; `false` otherwise.
  #
  # The persistence machinery checks this after running `around_*` callbacks to
  # decide whether the wrapped operation (save/create/update/destroy) actually
  # ran. Rarely needed in application code.
  #
  # ```
  # record.save
  # record.around_halted? # => true if an around_save callback never yielded
  # ```
  def around_halted? : Bool
    !!@_around_halted
  end

  # Halts the current persistence operation by raising
  # `Grant::Callbacks::Abort`. For saves, it rolls back the surrounding
  # save/create/update transaction, including when called from `after_create`,
  # `after_update`, or `after_save`. *message* is attached to the raised
  # exception.
  #
  # ```
  # class Account < Grant::Base
  #   column id : Int64, primary: true
  #   column locked : Bool = false
  #
  #   before_destroy :guard
  #
  #   private def guard
  #     abort!("locked accounts can't be destroyed") if locked
  #   end
  # end
  # ```
  def abort!(message = "Aborted at #{@_current_callback}.")
    raise Abort.new(message)
  end
end
