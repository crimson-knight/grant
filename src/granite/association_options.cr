# Advanced association options for Grant ORM
# 
# This module provides advanced association options like:
# - dependent: :destroy/:nullify/:restrict
# - counter_cache: true
# - inverse_of:
# - optional: true for belongs_to
# - autosave: true
# - touch: true

module Granite::AssociationOptions
  # Callback handler for dependent options
  module DependentCallbacks
    macro setup_dependent_destroy(association_name, association_type, target_class, foreign_key)
      after_destroy do
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).each(&.destroy)
        {% elsif association_type == :has_one %}
          if record = {{target_class.id}}.find_by({{foreign_key}}: self.primary_key_value)
            record.destroy
          end
        {% end %}
      end
    end
    
    macro setup_dependent_nullify(association_name, association_type, target_class, foreign_key)
      after_destroy do
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).each do |record|
            record.update!({{foreign_key}}: nil)
          end
        {% elsif association_type == :has_one %}
          if record = {{target_class.id}}.find_by({{foreign_key}}: self.primary_key_value)
            record.update!({{foreign_key}}: nil)
          end
        {% end %}
      end
    end
    
    macro setup_dependent_restrict(association_name, association_type, target_class, foreign_key)
      before_destroy do
        {% if association_type == :has_many %}
          if {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).exists?
            errors << Granite::Error.new(:base, "Cannot delete record because dependent {{association_name}} exist")
            abort!
          end
        {% elsif association_type == :has_one %}
          if {{target_class.id}}.find_by({{foreign_key}}: self.primary_key_value)
            errors << Granite::Error.new(:base, "Cannot delete record because dependent {{association_name}} exists")
            abort!
          end
        {% end %}
      end
    end
  end
  
  # Counter cache implementation
  module CounterCache
    macro setup_counter_cache(association_name, model_class, counter_column)
      # Increment counter on create
      after_create do
        if parent = self.{{association_name}}
          {{model_class.id}}.where(id: parent.id).update_all("{{counter_column}} = {{counter_column}} + 1")
        end
      end
      
      # Decrement counter on destroy
      after_destroy do
        if parent = self.{{association_name}}
          {{model_class.id}}.where(id: parent.id).update_all("{{counter_column}} = {{counter_column}} - 1")
        end
      end
      
      # Handle counter updates when association changes
      before_update do
        if changed?("{{association_name}}_id")
          old_id = attribute_was("{{association_name}}_id")
          new_id = self.{{association_name}}_id
          
          # Decrement old parent's counter
          if old_id
            {{model_class.id}}.where(id: old_id).update_all("{{counter_column}} = {{counter_column}} - 1")
          end
          
          # Increment new parent's counter
          if new_id
            {{model_class.id}}.where(id: new_id).update_all("{{counter_column}} = {{counter_column}} + 1")
          end
        end
      end
    end
  end
  
  # Touch implementation
  module TouchCallbacks
    macro setup_touch(association_name, touch_column = nil)
      after_save do
        if parent = self.{{association_name}}
          {% if touch_column %}
            parent.touch({{touch_column}})
          {% else %}
            parent.touch
          {% end %}
        end
      end
      
      after_destroy do
        if parent = self.{{association_name}}
          {% if touch_column %}
            parent.touch({{touch_column}})
          {% else %}
            parent.touch
          {% end %}
        end
      end
    end
  end
  
  # Autosave implementation
  module AutosaveCallbacks
    macro setup_autosave(association_name, association_type)
      before_save do
        {% if association_type == :belongs_to || association_type == :has_one %}
          if association = @_{{association_name}}_for_autosave
            association.save! unless association.persisted?
          end
        {% elsif association_type == :has_many %}
          if associations = @_{{association_name}}_for_autosave
            associations.each do |record|
              record.save! unless record.persisted?
            end
          end
        {% end %}
      end
    end
  end
  
  # Optional belongs_to validation
  module OptionalValidation
    macro setup_optional_validation(association_name, foreign_key, optional)
      {% unless optional %}
        validate "{{association_name}} must exist" do |model|
          !model.{{foreign_key}}.nil?
        end
      {% end %}
    end
  end
  
end