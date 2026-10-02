module Grant::AssociationOptions
  # Implements the `touch:` `belongs_to` option.
  module TouchCallbacks
    # Touches the parent whenever the child is saved or destroyed. Emitted by
    # `belongs_to ..., touch:`. With `touch: true` the parent's `updated_at` is
    # bumped; pass a column name to touch that column as well.
    #
    # The parent is touched by key with one UPDATE and is not loaded, unless it
    # has `after_touch` callbacks (or touches its own parent), in which case it
    # is loaded so they run. A save that changed nothing touches nothing, and
    # moving the child to another parent touches both the old and the new one.
    #
    # ```
    # class Comment < Grant::Base
    #   belongs_to :post, touch: true # post.updated_at bumps on comment save
    # end
    # ```
    macro setup_touch(association_name, touch_column, model_class, foreign_key, primary_key)
      private def _{{association_name.id}}_touch_parent(key) : Nil
        return if key.nil?
        return if {{model_class.id}}.no_touching?
        scope = {{model_class.id}}.unscoped.where({{primary_key}}, :eq, key.as(Grant::Columns::Type))
        if {{model_class.id}}.__touch_needs_instance?
          if parent = scope.first
            {% if touch_column %}
              parent.touch({{touch_column}})
            {% else %}
              parent.touch
            {% end %}
          end
        else
          {% if touch_column %}
            scope.touch_all({{touch_column}})
          {% else %}
            scope.touch_all
          {% end %}
        end
      end

      after_save do
        unless saved_changes.empty?
          _{{association_name.id}}_touch_parent(self.read_attribute({{foreign_key}}))
          if change = saved_change_to_attribute({{foreign_key}})
            old_key = change[0]
            _{{association_name.id}}_touch_parent(old_key.as(Grant::Columns::Type)) unless old_key.nil?
          end
        end
      end

      after_destroy do
        _{{association_name.id}}_touch_parent(self.read_attribute({{foreign_key}}))
      end

      # Touching this record touches its parent too, as in ActiveRecord.
      after_touch do
        _{{association_name.id}}_touch_parent(self.read_attribute({{foreign_key}}))
      end
    end
  end
end

module Grant::AssociationTouch
  # Defines `__touch_needs_instance?` on the including model class: true when a
  # `belongs_to touch:` must load the model to touch it because it has
  # `after_touch` callbacks (its own `belongs_to touch:` counts, since touching
  # cascades to its parent).
  macro define_touch_flag
    # :nodoc:
    def self.__touch_needs_instance? : Bool
      \{% begin %}
        \{%
           registered = false
           (@type.ancestors + [@type]).each do |ancestor|
             if ancestor.class? && ancestor.has_constant?("CALLBACKS")
               registered = true unless ancestor.constant("CALLBACKS")["after_touch"].empty?
             end
           end
        %}
        \{{registered}}
      \{% end %}
    end
  end
end
