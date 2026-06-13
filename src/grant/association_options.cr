# Implements the advanced options accepted by the association macros
# (`belongs_to`/`has_one`/`has_many`). You never call the macros in this module
# directly — you pass the corresponding option to an association macro and Grant
# installs the right lifecycle callbacks for you.
#
# | Option passed to the association     | Behaviour                                                                |
# | ------------------------------------ | ------------------------------------------------------------------------ |
# | `dependent: :destroy`                | Destroy dependent records (runs their callbacks) on owner destroy.       |
# | `dependent: :delete` / `:delete_all` | DELETE dependent records via one SQL statement (no callbacks).           |
# | `dependent: :nullify`                | Null out the dependents' foreign key on owner destroy.                   |
# | `dependent: :restrict`               | Block destroy with a validation error when dependents exist.             |
# | `dependent: :restrict_with_exception`| Raise `Grant::Associations::RestrictError` when dependents exist.        |
# | `counter_cache:` (`true`/column)     | Maintain a `<plural>_count` column on the parent.                        |
# | `touch:` (`true`/column)             | Update the parent's `updated_at` (or named column) when the child saves. |
# | `autosave: true`                     | Save an assigned-but-unpersisted associated record when the owner saves. |
# | `optional: true` (on `belongs_to`)   | Skip the auto presence validation on the foreign key.                    |
#
# ```
# class User < Grant::Base
#   has_many :posts, dependent: :destroy
# end
#
# class Post < Grant::Base
#   belongs_to :user, counter_cache: true, touch: true
#   # destroying a user now destroys their posts;
#   # saving a post bumps user.posts_count and user.updated_at
# end
# ```
module Grant::AssociationOptions
  # Installs the `after_destroy` / `before_destroy` callbacks behind the
  # `dependent:` association option. Each macro is emitted by an association
  # macro when you pass the matching `dependent:` value — you do not call them
  # directly.
  module DependentCallbacks
    # `dependent: :destroy` — when the owner is destroyed, load each dependent
    # record and call `destroy` on it (so the dependents' own callbacks run).
    #
    # ```
    # has_many :comments, dependent: :destroy
    # ```
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

    # `dependent: :nullify` — when the owner is destroyed, set the dependents'
    # foreign key to `nil` (orphaning them) rather than deleting them.
    #
    # ```
    # has_many :comments, dependent: :nullify
    # ```
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

    # Deletes all dependent records using a single SQL DELETE statement.
    #
    # Unlike `dependent: :destroy`, this does NOT instantiate records or
    # run their callbacks. It performs a direct SQL DELETE for performance.
    #
    # ```
    # has_many :comments, dependent: :delete_all
    # ```
    macro setup_dependent_delete_all(association_name, association_type, target_class, foreign_key)
      after_destroy do
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).delete_all
        {% elsif association_type == :has_one %}
          {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).delete_all
        {% end %}
      end
    end

    # `dependent: :restrict` — block the owner's destroy when dependents exist
    # by adding a `:base` validation error and aborting (a soft failure). Use
    # `:restrict_with_exception` instead to raise.
    #
    # ```
    # has_many :comments, dependent: :restrict
    # ```
    macro setup_dependent_restrict(association_name, association_type, target_class, foreign_key)
      before_destroy do
        {% if association_type == :has_many %}
          if {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).exists?
            errors << Grant::Error.new(:base, "Cannot delete record because dependent {{association_name}} exist")
            abort!
          end
        {% elsif association_type == :has_one %}
          if {{target_class.id}}.find_by({{foreign_key}}: self.primary_key_value)
            errors << Grant::Error.new(:base, "Cannot delete record because dependent {{association_name}} exists")
            abort!
          end
        {% end %}
      end
    end

    # `dependent: :restrict_with_exception` — raises `Grant::Associations::RestrictError`
    # when dependent records exist, instead of merely adding a validation error.
    #
    # Mirrors ActiveRecord's `:restrict_with_exception`.
    macro setup_dependent_restrict_with_exception(association_name, association_type, target_class, foreign_key)
      before_destroy do
        {% if association_type == :has_many %}
          if {{target_class.id}}.where({{foreign_key}}: self.primary_key_value).exists?
            raise Grant::Associations::RestrictError.new({{association_name.id.stringify}})
          end
        {% elsif association_type == :has_one %}
          if {{target_class.id}}.find_by({{foreign_key}}: self.primary_key_value)
            raise Grant::Associations::RestrictError.new({{association_name.id.stringify}})
          end
        {% end %}
      end
    end
  end

  # Implements the `counter_cache:` `belongs_to` option.
  module CounterCache
    # Keeps a counter column on the parent in sync with the number of children.
    # Emitted by `belongs_to ..., counter_cache:` — increments on create,
    # decrements on destroy, and adjusts both parents when the FK changes. With
    # `counter_cache: true` the column defaults to `<plural_model>_count` (e.g.
    # `posts_count`); pass a name to override it.
    #
    # ```
    # class Post < Grant::Base
    #   belongs_to :user, counter_cache: true # maintains User#posts_count
    # end
    # ```
    macro setup_counter_cache(association_name, model_class, counter_column)
      # Increment counter on create
      after_create do
        if parent = self.{{association_name}}
          {{model_class.id}}.where(id: parent.id).update_all({{counter_column.stringify}} + " = " + {{counter_column.stringify}} + " + 1")
        end
      end
      
      # Decrement counter on destroy
      after_destroy do
        if parent = self.{{association_name}}
          {{model_class.id}}.where(id: parent.id).update_all({{counter_column.stringify}} + " = " + {{counter_column.stringify}} + " - 1")
        end
      end
      
      # Handle counter updates when association changes
      before_update do
        if attribute_changed?("{{association_name}}_id")
          old_id = attribute_was("{{association_name}}_id")
          new_id = self.{{association_name}}_id
          
          # Decrement old parent's counter
          if old_id
            {{model_class.id}}.where(id: old_id).update_all({{counter_column.stringify}} + " = " + {{counter_column.stringify}} + " - 1")
          end
          
          # Increment new parent's counter
          if new_id
            {{model_class.id}}.where(id: new_id).update_all({{counter_column.stringify}} + " = " + {{counter_column.stringify}} + " + 1")
          end
        end
      end
    end
  end

  # Implements the `touch:` `belongs_to` option.
  module TouchCallbacks
    # Touches the parent whenever the child is saved or destroyed. Emitted by
    # `belongs_to ..., touch:`. With `touch: true` the parent's `updated_at` is
    # bumped; pass a column name to touch that column instead.
    #
    # ```
    # class Comment < Grant::Base
    #   belongs_to :post, touch: true # post.updated_at bumps on comment save
    # end
    # ```
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

  # Implements the `autosave: true` association option.
  module AutosaveCallbacks
    # On the owner's `before_save`, saves an assigned-but-unpersisted associated
    # record (or each record, for `has_many`). Emitted by an association macro
    # with `autosave: true`, which also overrides the setter to capture the
    # assigned record(s) for this callback to persist.
    #
    # ```
    # class User < Grant::Base
    #   has_one :profile, autosave: true
    # end
    #
    # user.profile = Profile.new(bio: "hi")
    # user.save # also saves the new profile
    # ```
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

  # Implements the presence validation `belongs_to` adds by default.
  module OptionalValidation
    # Adds a "<association> must exist" validation requiring the foreign key to
    # be present. Emitted automatically by `belongs_to` unless you pass
    # `optional: true`, which suppresses it (allowing a nil foreign key).
    #
    # ```
    # class Post < Grant::Base
    #   belongs_to :user                   # user_id presence is validated
    #   belongs_to :editor, optional: true # editor_id may be nil
    # end
    # ```
    macro setup_optional_validation(association_name, foreign_key, optional)
      {% unless optional %}
        validate "{{association_name}} must exist" do |model|
          !model.{{foreign_key}}.nil?
        end
      {% end %}
    end
  end
end
