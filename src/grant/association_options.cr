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
    # `dependent: :destroy` — destroy the dependents before the owner, inside
    # the same transaction, so foreign-key constraints and callbacks both work.
    #
    # ```
    # has_many :comments, dependent: :destroy
    # ```
    macro setup_dependent_destroy(association_name, association_type, target_class, foreign_key, primary_key)
      around_destroy do
        self.class.transaction do
          block.call
        end
      end
      before_destroy do
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).each do |record|
            abort!("Failed to destroy dependent {{association_name}}") unless record.destroy
          end
        {% elsif association_type == :has_one %}
          if record = {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).first
            abort!("Failed to destroy dependent {{association_name}}") unless record.destroy
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
    macro setup_dependent_nullify(association_name, association_type, target_class, foreign_key, primary_key)
      after_destroy do
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).each do |record|
            record.update!({{foreign_key}}: nil)
          end
        {% elsif association_type == :has_one %}
          if record = {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).first
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
    macro setup_dependent_delete_all(association_name, association_type, target_class, foreign_key, primary_key)
      after_destroy do
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).delete_all
        {% elsif association_type == :has_one %}
          {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).delete_all
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
    macro setup_dependent_restrict(association_name, association_type, target_class, foreign_key, primary_key)
      before_destroy do
        {% if association_type == :has_many %}
          if {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).exists?
            errors << Grant::Error.new(:base, "Cannot delete record because dependent {{association_name}} exist")
            abort!
          end
        {% elsif association_type == :has_one %}
          if {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).exists?
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
    macro setup_dependent_restrict_with_exception(association_name, association_type, target_class, foreign_key, primary_key)
      before_destroy do
        {% if association_type == :has_many %}
          if {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).exists?
            raise Grant::Associations::RestrictError.new({{association_name.id.stringify}})
          end
        {% elsif association_type == :has_one %}
          if {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).exists?
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
    macro setup_counter_cache(association_name, model_class, counter_column, foreign_key)
      {% if counter_column.is_a?(SymbolLiteral) %}
        {% counter_column_name = counter_column.id.stringify %}
      {% elsif counter_column.is_a?(StringLiteral) %}
        {% counter_column_name = counter_column.id.stringify %}
      {% else %}
        {% counter_column_name = counter_column.stringify.gsub(/"/, "") %}
      {% end %}
      # Increment counter on create
      after_create do
        if foreign_id = self.read_attribute({{foreign_key}})
          quoted_column = {{model_class.id}}.quote({{counter_column_name}})
          {{model_class.id}}.where({{model_class.id}}.primary_name, :eq, foreign_id)
            .update_all("#{quoted_column} = #{quoted_column} + 1")
        end
      end
      
      # Decrement counter on destroy
      after_destroy do
        if foreign_id = self.read_attribute({{foreign_key}})
          quoted_column = {{model_class.id}}.quote({{counter_column_name}})
          {{model_class.id}}.where({{model_class.id}}.primary_name, :eq, foreign_id)
            .update_all("#{quoted_column} = #{quoted_column} - 1")
        end
      end
      
      # Handle counter updates when association changes
      before_update do
        if attribute_changed?({{foreign_key}})
          old_id = attribute_was({{foreign_key}})
          new_id = self.read_attribute({{foreign_key}})
          quoted_column = {{model_class.id}}.quote({{counter_column_name}})
          
          # Decrement old parent's counter
          if old_id
            {{model_class.id}}.where({{model_class.id}}.primary_name, :eq, old_id.as(Grant::Columns::Type))
              .update_all("#{quoted_column} = #{quoted_column} - 1")
          end
          
          # Increment new parent's counter
          if new_id
            {{model_class.id}}.where({{model_class.id}}.primary_name, :eq, new_id)
              .update_all("#{quoted_column} = #{quoted_column} + 1")
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
    macro setup_autosave(association_name, association_type, foreign_key = nil, primary_key = nil)
      around_save do
        self.class.transaction do
          block.call
        end
      end

      before_save do
        {% if association_type == :belongs_to %}
          if association = @_{{association_name}}_for_autosave
            association.save! unless association.persisted?
            self.set_attributes({ {{foreign_key}} => association.read_attribute({{primary_key}}) })
          end
        {% end %}
      end

      {% if association_type == :has_one || association_type == :has_many %}
      after_save do
        {% if association_type == :has_one %}
          if association = @_{{association_name}}_for_autosave
            association.set_attributes({ {{foreign_key}} => self.read_attribute({{primary_key}}) })
            association.save! if !association.persisted? || association.changed?
          end
        {% elsif association_type == :has_many %}
          if associations = @_{{association_name}}_for_autosave
            associations.each do |record|
              record.set_attributes({ {{foreign_key}} => self.read_attribute({{primary_key}}) })
              record.save! if !record.persisted? || record.changed?
            end
          end
        {% end %}
      end
      {% end %}
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
    macro setup_optional_validation(association_name, foreign_key, target_class, primary_key, optional, autosave = false)
      {% unless optional %}
        validate "{{association_name}} must exist" do |model|
          if model._grant_nested_owner_foreign_key_skipped?({{foreign_key}})
            true
          else
            foreign_id = model.read_attribute({{foreign_key}})
            {% if autosave %}
              if foreign_id.nil? && model.@_{{association_name.id}}_for_autosave
                true
              else
                !foreign_id.nil? && {{target_class.id}}.where({{primary_key}}, :eq, foreign_id).exists?
              end
            {% else %}
              !foreign_id.nil? && {{target_class.id}}.where({{primary_key}}, :eq, foreign_id).exists?
            {% end %}
          end
        end
      {% end %}
    end
  end
end
