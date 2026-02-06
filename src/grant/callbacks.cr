module Grant::Callbacks
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
  @_around_halted : Bool = false

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
        \{% if callback_data.is_a? NamedTuple %}
          \{% callback = callback_data[:callback] %}
          \{% condition = callback_data[:if] %}
          \{% unless_condition = callback_data[:unless] %}
          if (\{% if condition %}\{{condition.id}}\{% else %}true\{% end %}) && !(\{% if unless_condition %}\{{unless_condition.id}}\{% else %}false\{% end %})
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

          \{% if callback_data.is_a? NamedTuple %}
            \{% callback = callback_data[:callback] %}
            \{% condition = callback_data[:if] %}
            \{% unless_condition = callback_data[:unless] %}

            if (\{% if condition %}\{{condition.id}}\{% else %}true\{% end %}) && !(\{% if unless_condition %}\{{unless_condition.id}}\{% else %}false\{% end %})
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

  # Returns true if the last around callback halted the operation.
  def around_halted? : Bool
    @_around_halted
  end

  def abort!(message = "Aborted at #{@_current_callback}.")
    raise Abort.new(message)
  end
end
