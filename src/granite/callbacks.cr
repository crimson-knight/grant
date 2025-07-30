module Granite::Callbacks
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

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @_current_callback : String?

  macro included
    macro inherited
      disable_granite_docs? CALLBACKS = {
        {% for name in CALLBACK_NAMES %}
          {{name.id}}: [] of Nil,
        {% end %}
      }
      {% for name in CALLBACK_NAMES %}
        disable_granite_docs? def {{name.id}}
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

  def abort!(message = "Aborted at #{@_current_callback}.")
    raise Abort.new(message)
  end
end
