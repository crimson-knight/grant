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
# - `after_commit` / `after_rollback` and the per-operation
#   `after_create_commit` / `after_update_commit` / `after_destroy_commit` —
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
# ## Halting
#
# Call `abort!` inside a `before_*` callback to raise `Grant::Callbacks::Abort`
# and stop the operation (the record is not persisted). An `around_*` callback
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
  # `before_*` callback. Caught by the persistence machinery, which reports the
  # failure instead of writing to the database.
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
    after_create_commit after_update_commit after_destroy_commit
  )

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
    macro {{name.id}}(*callbacks, if condition = nil, unless unless_condition = nil, &block)
      \{% for callback in callbacks %}
        \{% if condition || unless_condition %}
          \{% CALLBACKS[{{name}}] << {callback: callback, if: condition, unless: unless_condition} %}
        \{% else %}
          \{% CALLBACKS[{{name}}] << callback %}
        \{% end %}
      \{% end %}
      \{% if block.is_a? Block %}
        \{% if condition || unless_condition %}
          \{% CALLBACKS[{{name}}] << {callback: block, if: condition, unless: unless_condition} %}
        \{% else %}
          \{% CALLBACKS[{{name}}] << block %}
        \{% end %}
      \{% end %}
    end

    macro __{{name.id}}
      @_current_callback = {{name}}
      \{% for callback_data in CALLBACKS[{{name}}] %}
        \{% if callback_data.is_a? NamedTupleLiteral %}
          \{% callback = callback_data[:callback] %}
          \{% condition = callback_data[:if] %}
          \{% unless_condition = callback_data[:unless] %}
          # `if:`/`unless:` accept either a Symbol (instance method name) or a
          # Proc/lambda that receives the record. Symbols resolve to a bare
          # method call in instance context; Procs/Calls are invoked with `self`.
          if (\{% if condition %}\{% if condition.is_a?(SymbolLiteral) %}\{{condition.id}}\{% else %}(\{{condition}}).call(self)\{% end %}\{% else %}true\{% end %}) && !(\{% if unless_condition %}\{% if unless_condition.is_a?(SymbolLiteral) %}\{{unless_condition.id}}\{% else %}(\{{unless_condition}}).call(self)\{% end %}\{% else %}false\{% end %})
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
    macro {{name.id}}(*callbacks, if condition = nil, unless unless_condition = nil, &block)
      \{% for callback in callbacks %}
        \{% if condition || unless_condition %}
          \{% AROUND_CALLBACKS[{{name}}] << {callback: callback, if: condition, unless: unless_condition} %}
        \{% else %}
          \{% AROUND_CALLBACKS[{{name}}] << callback %}
        \{% end %}
      \{% end %}
      \{% if block.is_a? Block %}
        \{% if condition || unless_condition %}
          \{% AROUND_CALLBACKS[{{name}}] << {callback: block, if: condition, unless: unless_condition} %}
        \{% else %}
          \{% AROUND_CALLBACKS[{{name}}] << block %}
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

      \{% callbacks = AROUND_CALLBACKS[{{name}}] %}
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

            # See `__{{name.id}}` above: Symbol => method call, Proc/lambda => .call(self).
            if (\{% if condition %}\{% if condition.is_a?(SymbolLiteral) %}\{{condition.id}}\{% else %}(\{{condition}}).call(self)\{% end %}\{% else %}true\{% end %}) && !(\{% if unless_condition %}\{% if unless_condition.is_a?(SymbolLiteral) %}\{{unless_condition.id}}\{% else %}(\{{unless_condition}}).call(self)\{% end %}\{% else %}false\{% end %})
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
  # `Grant::Callbacks::Abort`. Intended for use inside a `before_*` callback:
  # the surrounding save/create/update/destroy is aborted and the record is not
  # written. *message* is attached to the raised exception.
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
