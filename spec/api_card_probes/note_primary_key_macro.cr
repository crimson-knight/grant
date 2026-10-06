require "./probe_support"

class GrantAPICardMacroModel < Grant::Base
  table :api_card_macro_models
  column id : Int64, primary: true
  column title : String

  def declared_instance_variable_names : Array(String)
    {{ @type.instance_vars.map(&.name.stringify) }}
  end

  macro has_unscoped_class_method?
    {% if @type.class.has_method?(:_unscoped?) %}
      true
    {% else %}
      false
    {% end %}
  end
end

GrantAPICardMacroModel.new.declared_instance_variable_names
GrantAPICardMacroModel.has_unscoped_class_method?
