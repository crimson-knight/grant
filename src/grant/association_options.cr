require "./dependent"
require "./counter_cache"
require "./association_touch"
require "./autosave"
require "./autosave/association_operations"

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
# | `dependent: :restrict_with_error`    | Block destroy with an error on `:base` when dependents exist (`:restrict` is the older name). |
# | `dependent: :restrict_with_exception`| Raise `Grant::Associations::RestrictError` when dependents exist.        |
# | `dependent: :destroy_async`          | Queue the destroy of the dependents (see `Grant::Dependent`).            |
# | `counter_cache:` (`true`/column)     | Maintain a `<plural>_count` column on the parent.                        |
# | `touch:` (`true`/column)             | Update the parent's `updated_at` (or named column) when the child saves. |
# | `autosave:` / `validate:` / `index_errors:` | Save and validate the associated records with the owner (see `Grant::Autosave`). |
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
    macro setup_optional_validation(association_name, foreign_key, target_class, primary_key, optional, autosave = nil)
      {% unless optional %}
        validate "{{association_name}} must exist" do |model|
          if model._grant_nested_owner_foreign_key_skipped?({{foreign_key}})
            true
          else
            foreign_id = model.read_attribute({{foreign_key}})
            if foreign_id.nil?
              model._{{association_name}}_assigned_for_autosave?
            else
              {{target_class.id}}.where({{primary_key}}, :eq, foreign_id).exists?
            end
          end
        end
      {% end %}
    end
  end
end
