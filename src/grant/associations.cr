require "./association_registry"
require "./polymorphic"
require "./association_options"

# Association macros for Grant models — `belongs_to`, `has_one`, `has_many`,
# `has_many ... through:`, and their polymorphic variants.
#
# Each macro is a **class-level DSL** you call in a model body. It generates
# instance methods at compile time, so the generated methods do **not** appear
# in `crystal docs` on their own — this module's doc comments describe exactly
# what each macro generates.
#
# ```
# class User < Grant::Base
#   connection sqlite
#   column id : Int64, primary: true
#   column name : String
#   has_many :posts
# end
#
# class Post < Grant::Base
#   connection sqlite
#   column id : Int64, primary: true
#   column title : String
#   belongs_to :user
# end
#
# user = User.find!(1)
# user.posts # => Grant::AssociationCollection of this user's posts
# user.posts.create(title: "Hello")
# post = Post.find!(1)
# post.user        # => User? (the owner, or a blank User if absent)
# post.user!       # => User (raises Grant::Querying::NotFound if absent)
# post.user = user # sets post.user_id = user.id
# user.post_ids    # => [1, 2, 3]
# ```
#
# ## What each macro generates
#
# | Macro                               | Generated API                                                |
# | ----------------------------------- | ------------------------------------------------------------ |
# | `belongs_to :user`                  | `#user`, `#user!`, `#user=`, and a `user_id : Int64?` column |
# | `has_one :profile`                  | `#profile`, `#profile!`, `#profile=`                         |
# | `has_many :posts`                   | `#posts` (collection), `#post_ids`, `#post_ids=`             |
# | `has_many :posts, through:`         | `#posts` (collection traversing the join table)              |
# | `belongs_to ..., polymorphic: true` | `#name`, `#name!`, `#name=`, `#name_proxy`, plus `*_id`/`*_type` columns |
#
# Common options accepted across the macros:
#
# * `class_name:` — target class when it cannot be inferred from the name.
# * `foreign_key:` — override the foreign-key column name.
# * `primary_key:` — override the referenced key (defaults to `"id"`).
# * `dependent:` — `:destroy` / `:delete` / `:delete_all` / `:nullify` /
#   `:restrict` / `:restrict_with_exception` (see `Grant::AssociationOptions`).
# * `optional: true` — skip the auto presence validation on a `belongs_to`.
# * `counter_cache:` / `touch:` / `autosave:` / `inverse_of:` — see
#   `Grant::AssociationOptions`.
#
# See `docs/associations.md` for the full guide.
module Grant::Associations
  include Grant::Polymorphic
  include Grant::AssociationOptions::DependentCallbacks
  include Grant::AssociationOptions::CounterCache
  include Grant::AssociationOptions::TouchCallbacks
  include Grant::AssociationOptions::AutosaveCallbacks
  include Grant::AssociationOptions::OptionalValidation

  # Declares that this model belongs to *model* — i.e. it holds the foreign key.
  #
  # Generates, for `belongs_to :user`:
  #
  # * `#user : User?` — loads the owner by foreign key, returns a blank `User`
  #   instance when the FK does not resolve (caches eager-loaded values).
  # * `#user! : User` — same, but raises `Grant::Querying::NotFound` when absent.
  # * `#user=(parent : User)` — sets `user_id` to `parent.id` (in memory; call
  #   `save` to persist).
  # * a `user_id : Int64?` column to hold the foreign key.
  #
  # *model* may be a bare name (`:user`) or a typed declaration
  # (`user : User`). Options:
  #
  # * `class_name:` — target class when it differs from the inferred name.
  # * `foreign_key:` — override the FK column (name, or a typed declaration like
  #   `foreign_key: author_id : Int64?` to set its column type).
  # * `primary_key:` — the key on the target this FK references (default `"id"`).
  # * `polymorphic: true` — make this a polymorphic `belongs_to` (see
  #   `Grant::Polymorphic`).
  # * `optional: true` — skip the auto presence validation on the FK.
  # * `counter_cache:` / `touch:` / `autosave:` / `inverse_of:` — see
  #   `Grant::AssociationOptions`.
  #
  # ```
  # class Post < Grant::Base
  #   connection sqlite
  #   column id : Int64, primary: true
  #   column title : String
  #   belongs_to :user          # => #user, #user!, #user=, user_id
  #   belongs_to author : User, # custom name + class + FK column
  #     class_name: User, foreign_key: author_id : Int64?
  # end
  #
  # post = Post.find!(1)
  # post.user  # => User? (blank User when user_id is nil/unresolved)
  # post.user! # => User  (raises Grant::Querying::NotFound if absent)
  # post.user = some_user
  # post.user_id # => some_user.id
  # ```
  macro belongs_to(model, **options)
    {% if options[:polymorphic] %}
      belongs_to_polymorphic({{model}}, {{options.double_splat}})
    {% else %}
    {% if model.is_a? TypeDeclaration %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% class_name = options[:class_name] || model.id.camelcase %}
    {% end %}

    {% if options[:foreign_key] && options[:foreign_key].is_a? TypeDeclaration %}
      {% foreign_key = options[:foreign_key].var %}
      column {{options[:foreign_key]}}{% if options[:primary] %}, primary: {{options[:primary]}}{% end %}{% if options[:converter] %}, converter: {{options[:converter]}}{% end %}
    {% else %}
      {% foreign_key = method_name + "_id" %}
      column {{foreign_key}} : Int64?{% if options[:primary] %}, primary: {{options[:primary]}}{% end %}{% if options[:converter] %}, converter: {{options[:converter]}}{% end %}
    {% end %}
    {% primary_key = options[:primary_key] || "id" %}

    {% inverse_of_bt = options[:inverse_of] %}

    @[Grant::Relationship(target: {{class_name.id}}, type: :belongs_to,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}})]
    def {{method_name.id}} : {{class_name.id}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      elsif parent = {{class_name.id}}.find_by({{primary_key.id}}: {{foreign_key.id}})
        Grant::Logs::Association.debug { "Loaded belongs_to association - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [fk: #{{{foreign_key.id.stringify}}} = #{{{foreign_key.id}}}]" }
        {% if inverse_of_bt %}
          parent.set_loaded_association({{inverse_of_bt.id.stringify}}, self)
        {% end %}
        parent
      else
        {{class_name.id}}.new
      end
    end

    def {{method_name.id}}! : {{class_name.id}}
      result = {{class_name.id}}.find_by!({{primary_key.id}}: {{foreign_key.id}})
      {% if inverse_of_bt %}
        result.set_loaded_association({{inverse_of_bt.id.stringify}}, self)
      {% end %}
      result
    end

    def {{method_name.id}}=(parent : {{class_name.id}})
      @{{foreign_key.id}} = parent.{{primary_key.id}}
    end
    
    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :belongs_to,
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      primary_key: {{primary_key.id.stringify}},
      through: nil
    }

    # Populate the runtime association registry so reflection works.
    _grant_register_association({{method_name.id.stringify}}, :belongs_to, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}}, nil)

    # Handle optional validation
    {% unless options[:optional] %}
      setup_optional_validation({{method_name.id}}, {{foreign_key.id}}, false)
    {% end %}
    
    # Handle counter cache
    {% if options[:counter_cache] %}
      {% counter_column = options[:counter_cache] == true ? @type.stringify.split("::").last.underscore + "s_count" : options[:counter_cache] %}
      setup_counter_cache({{method_name.id}}, {{class_name.id}}, {{counter_column}})
    {% end %}
    
    # Handle touch
    {% if options[:touch] %}
      {% touch_column = options[:touch] == true ? nil : options[:touch] %}
      setup_touch({{method_name.id}}, {{touch_column}})
    {% end %}
    
    # Handle autosave
    {% if options[:autosave] %}
      setup_autosave({{method_name.id}}, :belongs_to)
      
      # Define instance variable for tracking autosave
      @_{{method_name.id}}_for_autosave : {{class_name.id}}? = nil
      
      # Override setter to track autosave
      def {{method_name.id}}=(parent : {{class_name.id}})
        @{{foreign_key.id}} = parent.{{primary_key.id}}
        @_{{method_name.id}}_for_autosave = parent
      end
    {% end %}
    {% end %}
  end

  # Declares a one-to-one association where the **other** table holds the
  # foreign key (the inverse of `belongs_to`).
  #
  # Generates, for `has_one :profile` on `User`:
  #
  # * `#profile : Profile?` — finds the `Profile` whose `user_id` equals this
  #   user's primary key (or `nil`), caching eager-loaded values.
  # * `#profile! : Profile` — same, but raises `Grant::Querying::NotFound`.
  # * `#profile=(child)` — sets the child's `user_id` to this user's primary key
  #   (in memory; `save` the child to persist).
  #
  # Options:
  #
  # * `class_name:` — target class when it differs from the inferred name.
  # * `foreign_key:` — the FK column on the target (default
  #   `"<this_model>_id"`).
  # * `primary_key:` — the key on this model the FK references (default `"id"`;
  #   a typed declaration also defines that column).
  # * `through:` — traverse an intermediate association to reach a single record
  #   (e.g. `has_one :avatar, through: :profile`); pair with `source:` to name
  #   the association on the join model. The `through` form generates only the
  #   getters (`#avatar` / `#avatar!`), not a setter.
  # * `as:` — make this the `has_one` side of a polymorphic association (see
  #   `Grant::Polymorphic`).
  # * `dependent:` / `autosave:` / `inverse_of:` — see
  #   `Grant::AssociationOptions`.
  #
  # ```
  # class User < Grant::Base
  #   connection sqlite
  #   column id : Int64, primary: true
  #   has_one :profile                   # Profile.user_id => this user
  #   has_one :avatar, through: :profile # User -> Profile -> Avatar
  # end
  #
  # user = User.find!(1)
  # user.profile  # => Profile? (where profiles.user_id = user.id)
  # user.profile! # => Profile  (raises Grant::Querying::NotFound if absent)
  # user.avatar   # => Avatar? (joined through profiles)
  # ```
  macro has_one(model, **options)
    {% if options[:as] %}
      has_one_polymorphic({{model}}, {{options[:as]}}, {{options.double_splat}})
    {% elsif options[:through] %}
      # has_one :through — traverses an intermediate association to find a single target record
      {% if model.is_a? TypeDeclaration %}
        {% method_name = model.var %}
        {% class_name = model.type %}
      {% else %}
        {% method_name = model.id %}
        {% class_name = options[:class_name] || model.id.camelcase %}
      {% end %}
      {% through = options[:through] %}
      {% foreign_key = options[:foreign_key] || @type.stringify.split("::").last.underscore + "_id" %}
      {% primary_key = options[:primary_key] || "id" %}
      {% source = options[:source] || method_name %}

      @[Grant::Relationship(target: {{class_name.id}}, type: :has_one,
        primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}})]

      # Returns the associated record through an intermediate table.
      #
      # Uses a JOIN query through the `{{through.id}}` table to find
      # the single `{{class_name.id}}` record.
      #
      # ```
      # record = owner.{{method_name.id}}
      # ```
      def {{method_name}} : {{class_name}}?
        if association_loaded?({{method_name.stringify}})
          get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
        else
          # Build JOIN query through the intermediate table
          # e.g. SELECT avatars.* FROM avatars
          #      JOIN profiles ON profiles.avatar_id = avatars.id
          #      WHERE profiles.user_id = ? LIMIT 1
          #
          # The join key is the FK on the join model that references the target.
          # When an explicit `source:` is given it names that association on the
          # join model, so the FK is `<source>_id`. Otherwise it derives from
          # the target class name (or a custom non-"id" primary_key).
          {% if options[:source] %}
            key = {{source.id.stringify}} + "_id"
          {% else %}
            key = {{primary_key.id.stringify}} == "id" ? "#{{{class_name.id}}.to_s.underscore}_id" : {{primary_key.id.stringify}}
          {% end %}
          sql = String.build do |s|
            s << "JOIN #{{{through.id.stringify}}} ON #{{{through.id.stringify}}}.#{key} = #{{{class_name.id}}.table_name}.#{{{class_name.id}}.primary_name} "
            s << "WHERE #{{{through.id.stringify}}}.#{{{foreign_key.id.stringify}}} = ?"
          end
          result = {{class_name.id}}.first(sql, [self.{{primary_key.id}}])
          if result
            Grant::Logs::Association.debug { "Loaded has_one :through association - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [through: #{{{through.id.stringify}}}]" }
          end
          result
        end
      end

      # Returns the associated record through an intermediate table, raising if not found.
      def {{method_name}}! : {{class_name}}
        {{method_name}} || raise Grant::Querying::NotFound.new("No #{{{class_name.id.stringify}}} found through #{{{through.id.stringify}}} for #{self.class.name}")
      end

      # Store association metadata
      class_getter _{{method_name.id}}_association_meta = {
        type: :has_one,
        target_class_name: {{class_name.id.stringify}},
        foreign_key: {{foreign_key.id.stringify}},
        primary_key: {{primary_key.id.stringify}},
        through: {{through.id.stringify}}
      }

      # Populate the runtime association registry so reflection works.
      _grant_register_association({{method_name.id.stringify}}, :has_one, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}}, {{through.id.stringify}})
    {% else %}
    {% if model.is_a? TypeDeclaration %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% class_name = options[:class_name] || model.id.camelcase %}
    {% end %}
    {% foreign_key = options[:foreign_key] || @type.stringify.split("::").last.underscore + "_id" %}

    {% if options[:primary_key] && options[:primary_key].is_a? TypeDeclaration %}
      {% primary_key = options[:primary_key].var %}
      column {{options[:primary_key]}}
    {% else %}
      {% primary_key = options[:primary_key] || "id" %}
    {% end %}

    @[Grant::Relationship(target: {{class_name.id}}, type: :has_one,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}})]

    {% inverse_of = options[:inverse_of] %}

    def {{method_name}} : {{class_name}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      else
        result = {{class_name.id}}.find_by({{foreign_key.id}}: self.{{primary_key.id}})
        if result
          Grant::Logs::Association.debug { "Loaded has_one association - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [fk: #{{{foreign_key.id.stringify}}} = #{self.{{primary_key.id}}}]" }
          {% if inverse_of %}
            result.set_loaded_association({{inverse_of.id.stringify}}, self)
          {% end %}
        end
        result
      end
    end

    def {{method_name}}! : {{class_name}}
      result = {{class_name.id}}.find_by!({{foreign_key.id}}: self.{{primary_key.id}})
      {% if inverse_of %}
        result.set_loaded_association({{inverse_of.id.stringify}}, self)
      {% end %}
      result
    end

    def {{method_name}}=(child)
      child.{{foreign_key.id}} = self.{{primary_key.id}}
    end

    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_one,
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      primary_key: {{primary_key.id.stringify}},
      through: nil
    }

    # Populate the runtime association registry so reflection works.
    _grant_register_association({{method_name.id.stringify}}, :has_one, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}}, nil)

    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        setup_dependent_destroy({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :delete %}
        setup_dependent_delete_all({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :nullify %}
        setup_dependent_nullify({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :restrict %}
        setup_dependent_restrict({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :restrict_with_exception %}
        setup_dependent_restrict_with_exception({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% end %}
    {% end %}

    # Handle autosave
    {% if options[:autosave] %}
      setup_autosave({{method_name.id}}, :has_one)

      # Define instance variable for tracking autosave
      @_{{method_name.id}}_for_autosave : {{class_name.id}}? = nil

      # Override setter to track autosave
      def {{method_name}}=(child)
        child.{{foreign_key.id}} = self.{{primary_key.id}}
        @_{{method_name.id}}_for_autosave = child
      end
    {% end %}
    {% end %}
  end

  # Declares a one-to-many association where the **other** table holds the
  # foreign key.
  #
  # Generates, for `has_many :posts` on `User`:
  #
  # * `#posts` — returns a `Grant::AssociationCollection(User, Post)` (or a
  #   `Grant::LoadedAssociationCollection` when eager-loaded). The collection is
  #   `Enumerable` and also exposes `build`/`create`/`create!`/`find`/`find_by`/
  #   `where`/`destroy_all`/`delete_all` (see `Grant::AssociationCollection`).
  # * `#post_ids : Array` — the primary keys of the associated records.
  # * `#post_ids=(ids : Array)` — reassigns the collection by primary key:
  #   records whose IDs are listed have their FK pointed at this owner; records
  #   previously in the collection but absent from *ids* have their FK nullified.
  #   (Not generated for `through:` associations.)
  #
  # The optional second positional argument *scope* is an association scope
  # lambda that further filters the collection, e.g.
  # `has_many :published_posts, ->(q : Grant::Query::Builder(Post)) { q.where(published: true) }`.
  #
  # ## Inferred target class name
  #
  # When `class_name:` is omitted, the target class is inferred from the
  # (plural) association name by **singularizing** then camelizing it, matching
  # the Rails idiom: `has_many :books` → `Book`, `has_many :categories` →
  # `Category`, `has_many :boxes` → `Box`, `has_many :book_reviews` →
  # `BookReview`.
  #
  # The built-in singularizer only handles **regular** English plurals:
  #
  # * `...ies` → `...y` (`categories` → `category`)
  # * `...ses` / `...xes` / `...zes` / `...ches` / `...shes` → drop `es`
  #   (`boxes` → `box`, `dishes` → `dish`)
  # * `...s` (but not `...ss`) → drop `s` (`books` → `book`)
  # * anything else is left unchanged.
  #
  # **Irregular plurals** (`people`, `children`, `mice`, `quizzes`, etc.) are
  # NOT handled — pass `class_name:` explicitly for those:
  # `has_many :people, class_name: Person`.
  #
  # Options:
  #
  # * `class_name:` — target class when it differs from the inferred name
  #   (always wins over the inferred singular name; required for irregular
  #   plurals).
  # * `foreign_key:` — the FK column on the target (default
  #   `"<this_model>_id"`).
  # * `primary_key:` — the key on this model the FK references (default `"id"`).
  # * `through:` — a join model/table for many-to-many (e.g.
  #   `has_many :tags, through: :taggings`); pair with `source:` to name the
  #   association on the join model whose target is collected.
  # * `as:` — make this the `has_many` side of a polymorphic association.
  # * `dependent:` / `inverse_of:` / `autosave:` — see
  #   `Grant::AssociationOptions`.
  #
  # ```
  # class User < Grant::Base
  #   connection sqlite
  #   column id : Int64, primary: true
  #   has_many :posts
  #   has_many :tags, through: :taggings # many-to-many via taggings
  # end
  #
  # user = User.find!(1)
  # user.posts.create(title: "Hello") # builds + saves with user_id pre-set
  # user.posts.where(published: true).to_a
  # user.post_ids          # => [1, 2, 3]
  # user.post_ids = [1, 2] # repoint FKs: keep 1,2 / nullify others
  # user.tags.to_a         # joined through taggings
  # ```
  macro has_many(model, scope = nil, **options)
    {% if options[:as] %}
      has_many_polymorphic({{model}}, {{options[:as]}}, {{options.double_splat}})
    {% else %}
    {% if model.is_a? TypeDeclaration %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% if options[:class_name] %}
        # Explicit override always wins (required for irregular plurals).
        {% class_name = options[:class_name] %}
      {% else %}
        # Infer the target class by singularizing the (plural) association
        # name and camelizing it: `:books` -> `Book`, `:categories` ->
        # `Category`, `:boxes` -> `Box`. Only REGULAR English plurals are
        # handled; irregular plurals (people, children, ...) require an
        # explicit `class_name:`.
        {% _w = model.id.stringify %}
        {% if _w.ends_with?("ies") %}
          {% _singular = _w[0...(_w.size - 3)] + "y" %}
        {% elsif _w.ends_with?("ses") || _w.ends_with?("xes") || _w.ends_with?("zes") || _w.ends_with?("ches") || _w.ends_with?("shes") %}
          {% _singular = _w[0...(_w.size - 2)] %}
        {% elsif _w.ends_with?("s") && !_w.ends_with?("ss") %}
          {% _singular = _w[0...(_w.size - 1)] %}
        {% else %}
          {% _singular = _w %}
        {% end %}
        {% class_name = _singular.camelcase %}
      {% end %}
    {% end %}
    {% foreign_key = options[:foreign_key] || @type.stringify.split("::").last.underscore + "_id" %}
    {% primary_key = options[:primary_key] || "id" %}
    {% through = options[:through] %}
    {% inverse_of = options[:inverse_of] %}
    # `source:` names the association on the join model whose target is collected
    # for `:through`. When absent it defaults to the singular form of method_name.
    {% source = options[:source] %}
    @[Grant::Relationship(target: {{class_name.id}}, through: {{through.id}}, type: :has_many,
      primary_key: {{through}}, foreign_key: {{foreign_key.id}})]
    def {{method_name.id}}
      {% if scope %}
        scope_proc = ->(q : Grant::Query::Builder({{class_name.id}})) { q.{{scope.body}} }
      {% else %}
        scope_proc = nil
      {% end %}
      {% if through && source %}
        {% join_pk = "#{source.id}_id" %}
      {% else %}
        {% join_pk = primary_key %}
      {% end %}
      if association_loaded?({{method_name.stringify}})
        loaded_data = get_loaded_association({{method_name.stringify}})
        if loaded_data.is_a?(Array(Grant::Base))
          # Return a wrapper that behaves like AssociationCollection but uses loaded data
          Grant::LoadedAssociationCollection(self, {{class_name.id}}).new(loaded_data.map(&.as({{class_name.id}})))
        else
          Grant::AssociationCollection(self, {{class_name.id}}).new(self, {{foreign_key}}, {{through}}, {{through && source ? join_pk : primary_key}}, {{inverse_of}}, scope_proc)
        end
      else
        Grant::Logs::Association.debug { "Created has_many association collection - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [fk: #{{{foreign_key.id.stringify}}}]#{{{through ? " [through: " + through.id.stringify + "]" : ""}}}" }
        Grant::AssociationCollection(self, {{class_name.id}}).new(self, {{foreign_key}}, {{through}}, {{through && source ? join_pk : primary_key}}, {{inverse_of}}, scope_proc)
      end
    end

    # Collection of associated primary keys, e.g. `user.post_ids`.
    def {{method_name.id[0..-2]}}_ids
      {{method_name.id}}.map(&.primary_key_value).to_a
    end

    # Assigns the collection by primary keys, e.g. `user.post_ids = [1, 2, 3]`.
    # Records whose IDs are listed have their foreign key pointed at this owner;
    # records previously in the collection but absent from *ids* are nullified.
    {% unless through %}
    def {{method_name.id[0..-2]}}_ids=(ids : Array)
      string_ids = ids.map(&.to_s)
      # Nullify records no longer in the set
      {{class_name.id}}.where({{foreign_key.id}}: self.primary_key_value).each do |record|
        unless string_ids.includes?(record.primary_key_value.to_s)
          record.{{foreign_key.id}} = nil
          record.save
        end
      end
      # Point listed records at this owner
      ids.each do |pk|
        if record = {{class_name.id}}.find(pk)
          record.{{foreign_key.id}} = self.primary_key_value
          record.save
        end
      end
      ids
    end
    {% end %}

    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_many,
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      primary_key: {{primary_key.id.stringify}},
      through: {{through ? through.id.stringify : nil}}
    }

    # Populate the runtime association registry so reflection works.
    _grant_register_association({{method_name.id.stringify}}, :has_many, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}}, {{through ? through.id.stringify : nil}})

    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        setup_dependent_destroy({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :delete_all %}
        setup_dependent_delete_all({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :nullify %}
        setup_dependent_nullify({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :restrict %}
        setup_dependent_restrict({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :restrict_with_exception %}
        setup_dependent_restrict_with_exception({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% end %}
    {% end %}

    # Handle autosave
    {% if options[:autosave] %}
      setup_autosave({{method_name.id}}, :has_many)
      
      # Define instance variable for tracking autosave records
      @_{{method_name.id}}_for_autosave : Array({{class_name.id}})? = nil
      
      # Override accessor to track autosave records
      def {{method_name.id}}=(records : Array({{class_name.id}}))
        records.each do |record|
          record.{{foreign_key.id}} = self.{{primary_key.id}}
        end
        @_{{method_name.id}}_for_autosave = records
      end
    {% end %}
    {% end %}
  end

  # Returns the compile-time metadata `NamedTuple` recorded for the association
  # named *name* (`type`, `target_class_name`, `foreign_key`, `primary_key`,
  # `through`). Useful for reflection over a model's declared associations.
  #
  # ```
  # class Post < Grant::Base
  #   belongs_to :user
  # end
  #
  # Post.new.association_metadata(:user)[:foreign_key] # => "user_id"
  # ```
  macro association_metadata(name)
    self.class._{{name.id}}_association_meta
  end

  # Registers association metadata into the runtime `AssociationRegistry` so that
  # `Grant::AssociationRegistry.get(model_class, name)` reflection works without
  # recompilation. Emitted by each association macro. The registration call is
  # placed at class-body level so it executes once when the model class loads.
  macro _grant_register_association(name, type, target_class, foreign_key, primary_key, through)
    Grant::AssociationRegistry.register(
      {{@type.name.stringify}},
      {{name}},
      {
        type:         {{type}},
        target_class: {{target_class.id}},
        foreign_key:  {{foreign_key}},
        primary_key:  {{primary_key}},
        through:      {{through}},
      }
    )
  end
end
