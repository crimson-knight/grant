require "./association_registry"
require "./reflection"
require "./polymorphic"
require "./delegated_type"
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
#   `:restrict_with_error` (`:restrict`) / `:restrict_with_exception` /
#   `:destroy_async` (see `Grant::AssociationOptions`). An unsupported value is a
#   compile error.
# * `optional: true` — skip the auto presence validation on a `belongs_to`.
# * `counter_cache:` / `touch:` / `autosave:` / `validate:` / `index_errors:` /
#   `inverse_of:` — see `Grant::AssociationOptions`.
# * `default:` (on `belongs_to`) — a proc that supplies the parent when the key is
#   missing on create.
#
# See `docs/advanced_associations.md` for the full guide.
module Grant::Associations
  include Grant::Polymorphic
  include Grant::DelegatedType
  include Grant::AssociationOptions::DependentCallbacks
  include Grant::AssociationOptions::CounterCache
  include Grant::AssociationOptions::TouchCallbacks
  include Grant::AssociationOptions::AutosaveCallbacks
  include Grant::AssociationOptions::OptionalValidation
  include Grant::Autosave
  include Grant::Dependent::Instance
  include Grant::CounterCache::Instance

  macro included
    extend Grant::CounterCache::ClassMethods
    Grant::AssociationTouch.define_touch_flag
  end

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
  # * `#build_user(**attributes) : User`, `#create_user(**attributes) : User` and
  #   `#create_user!(**attributes) : User` — build or create the parent and assign
  #   it. The owner itself is not saved; a built parent is saved with it.
  #
  # An option the macro does not know (`foriegn_key:`) or a `dependent:` value
  # it does not support fails the build, with the valid ones listed.
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
  macro belongs_to(model, scope = nil, **options)
    _grant_check_association_options(:belongs_to, {{model}}, {{options.keys.map(&.stringify)}} of String, {{options[:through] ? true : false}}, {{options[:source_type] ? true : false}})
    {% if options[:foreign_key].is_a?(TupleLiteral) || options[:foreign_key].is_a?(ArrayLiteral) || options[:query_constraints] %}
      composite_belongs_to({{model}}, {{scope}}, {% for key, value in options %}{{key.id}}: {{value}}, {% end %})
    {% elsif options[:polymorphic] %}
      {% if options[:foreign_key].is_a?(TypeDeclaration) %}
        column {{options[:foreign_key]}}
        belongs_to_polymorphic({{model}}, foreign_key_declared: true, {% for key, value in options %}{% if key.stringify == "foreign_key" %}foreign_key: {{value.var.stringify}}, {% else %}{{key.id}}: {{value}}, {% end %}{% end %})
      {% else %}
        belongs_to_polymorphic({{model}}, {% for key, value in options %}{{key.id}}: {{value}}, {% end %})
      {% end %}
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
    {% elsif options[:foreign_key] %}
      {% foreign_key = options[:foreign_key].id %}
    {% else %}
      {% foreign_key = method_name + "_id" %}
      column {{foreign_key}} : Int64?{% if options[:primary] %}, primary: {{options[:primary]}}{% end %}{% if options[:converter] %}, converter: {{options[:converter]}}{% end %}
    {% end %}
    {% primary_key = options[:primary_key] || "id" %}
    {% foreign_key_name = foreign_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% primary_key_name = primary_key.stringify.gsub(/:/, "").gsub(/"/, "") %}

    {% inverse_of_bt = options[:inverse_of] %}

    @[Grant::Relationship(target: {{class_name.id}}, type: :belongs_to,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}}, scope: {{scope}})]
    def {{method_name.id}} : {{class_name.id}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      else
        assert_association_can_lazy_load!({{method_name.stringify}}, {{options[:strict_loading]}})
        relation = {{class_name.id}}.where({{primary_key_name}}, :eq, {{foreign_key.id}})
        {% if scope.is_a?(ProcLiteral) %}
          {% if scope.args.empty? %}
            relation = relation.{{scope.body}}
          {% else %}
            relation = {{scope}}.call(relation)
          {% end %}
        {% end %}
        if parent = relation.first
          Grant::Logs::Association.debug { "Loaded belongs_to association - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [fk: #{{{foreign_key.id.stringify}}} = #{{{foreign_key.id}}}]" }
          _adopt_strict_loading(parent, false)
        {% if inverse_of_bt %}
          parent.set_loaded_association({{inverse_of_bt.id.stringify}}, self)
        {% end %}
          parent
        else
          nil
        end
      end
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{method_name.stringify}})
    end

    def reload_{{method_name.id}} : {{class_name.id}}?
      reload_association({{method_name.stringify}})
      {{method_name.id}}
    end

    def {{method_name.id}}! : {{class_name.id}}
      if association_loaded?({{method_name.stringify}})
        foreign_value = read_attribute({{foreign_key_name}})
        foreign_value_text = foreign_value.nil? ? "NULL" : foreign_value.to_s
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?) || raise Grant::Querying::NotFound.new("No {{class_name.id}} found where #{{{primary_key_name}}} is #{foreign_value_text}")
      else
        foreign_value = read_attribute({{foreign_key_name}})
        foreign_value_text = foreign_value.nil? ? "NULL" : foreign_value.to_s
        {{method_name.id}} || raise Grant::Querying::NotFound.new("No {{class_name.id}} found where #{{{primary_key_name}}} is #{foreign_value_text}")
      end
    end

    def {{method_name.id}}=(parent : {{class_name.id}}?)
      if parent
        parent_key = parent.read_attribute({{primary_key_name}})
        if parent_key.nil?
          clear_nullable_attribute({{foreign_key_name}})
        else
          converted_key = Grant::Type.convert_type(parent_key, typeof(self.{{foreign_key.id}}))
          self.{{foreign_key.id}} = converted_key.as(typeof(self.{{foreign_key.id}}))
        end
      else
        clear_nullable_attribute({{foreign_key_name}})
      end
      set_loaded_association({{method_name.stringify}}, parent)
    end

    _grant_define_belongs_to_builders({{method_name}}, {{class_name}})

    # True when the foreign key changed since the record was loaded or last
    # saved, or a new, unsaved parent is assigned.
    def {{method_name.id}}_changed? : Bool
      return true if attribute_changed?({{foreign_key_name}})
      if association_loaded?({{method_name.stringify}})
        parent = get_loaded_association({{method_name.stringify}}).as?({{class_name.id}})
        return !parent.nil? && parent.new_record?
      end
      false
    end

    # True when the last save changed the foreign key.
    def {{method_name.id}}_previously_changed? : Bool
      saved_change_to_attribute?({{foreign_key_name}})
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
    _grant_register_reflection({{method_name.id.stringify}}, :belongs_to, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}},
      nil, nil, nil, nil, {{options[:dependent]}}, {{inverse_of_bt ? inverse_of_bt.id.stringify : nil}}, {{options[:inverse_of] == false}},
      {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    Grant::Dependent.check_dependent_option(:belongs_to, {{method_name}}, {{options[:dependent]}})

    # Handle optional validation
    {% unless options[:optional] %}
      setup_optional_validation({{method_name.id}}, {{foreign_key_name}}, {{class_name.id}}, {{primary_key_name}}, false)
    {% end %}

    # `default:` fills a missing parent key before validation on create.
    {% if options[:default] %}
      before_validation on: :create do
        if read_attribute({{foreign_key_name}}).nil?
          if default_parent = ({{options[:default]}}).call(self)
            self.{{method_name.id}} = default_parent
          end
        end
      end
    {% end %}

    # Handle counter cache
    {% if options[:counter_cache] %}
      {% counter_option = options[:counter_cache] %}
      {% if counter_option == true %}
        setup_counter_cache({{method_name.id}}, {{class_name.id}}, nil, {{foreign_key_name}})
      {% elsif counter_option.is_a?(NamedTupleLiteral) %}
        setup_counter_cache({{method_name.id}}, {{class_name.id}}, {{counter_option[:column]}}, {{foreign_key_name}}, {{counter_option[:active] == false ? false : true}})
      {% elsif counter_option.is_a?(SymbolLiteral) %}
        setup_counter_cache({{method_name.id}}, {{class_name.id}}, {{counter_option.id.stringify}}, {{foreign_key_name}})
      {% else %}
        setup_counter_cache({{method_name.id}}, {{class_name.id}}, {{counter_option.stringify.gsub(/"/, "")}}, {{foreign_key_name}})
      {% end %}
    {% end %}

    # Handle touch
    {% if options[:touch] %}
      {% touch_column = options[:touch] == true ? nil : options[:touch] %}
      setup_touch({{method_name.id}}, {{touch_column}}, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
    {% end %}

    # Handle dependent
    {% if options[:dependent] %}
      setup_dependent_belongs_to({{method_name.id}}, {{options[:dependent]}}, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
    {% end %}

    # Autosave, validation of an assigned parent and index_errors
    setup_autosave({{method_name.id}}, :belongs_to, {{class_name.id}}, {{foreign_key_name}}, {{options[:primary_key] ? primary_key_name : nil}}, {{options[:autosave]}}, {{options[:validate]}}, {{options[:index_errors]}})
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
  # * `#build_profile(**attributes)`, `#create_profile(**attributes)` and
  #   `#create_profile!(**attributes)` — build or create the child with this
  #   user's key and make it the loaded target. A child already attached to a
  #   saved user is displaced as `dependent:` says (destroyed, deleted, or its
  #   key cleared). `create_profile` needs a saved user.
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
  #   getters (`#avatar` / `#avatar!`), not a setter. `source_type:` names the
  #   class of a polymorphic source.
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
  macro has_one(model, scope = nil, **options)
    _grant_check_association_options(:has_one, {{model}}, {{options.keys.map(&.stringify)}} of String, {{options[:through] ? true : false}}, {{options[:source_type] ? true : false}})
    {% if options[:foreign_key].is_a?(TupleLiteral) || options[:foreign_key].is_a?(ArrayLiteral) || options[:query_constraints] %}
      composite_has_one({{model}}, {{scope}}, {% for key, value in options %}{{key.id}}: {{value}}, {% end %})
    {% elsif options[:as] %}
      has_one_polymorphic({{model}}, {{options[:as]}}, {% for key, value in options %}{{key.id}}: {{value}}, {% end %})
    {% elsif options[:through] %}
      # has_one :through — traverses an intermediate association to find a single target record
      {% if model.is_a? TypeDeclaration %}
        {% method_name = model.var %}
        {% class_name = model.type %}
      {% else %}
        {% method_name = model.id %}
        {% class_name = options[:class_name] || options[:source_type] || model.id.camelcase %}
      {% end %}
      {% through = options[:through] %}
      {% foreign_key = options[:foreign_key] || @type.stringify.split("::").last.underscore + "_id" %}
      {% primary_key = options[:primary_key] || "id" %}
      {% foreign_key_name = foreign_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
      {% primary_key_name = primary_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
      {% source = options[:source] || method_name %}
      # `through:` names an association on this model (ActiveRecord form). A
      # name that is not an association is read as the join table, the older
      # form, which only supports the lazy reader.
      {% through_is_association = false %}
      {% for candidate in @type.methods %}
        {% if candidate.name.stringify == through.id.stringify && candidate.annotation(Grant::Relationship) %}
          {% through_is_association = true %}
        {% end %}
      {% end %}

      @[Grant::Relationship(target: {{class_name.id}}, type: :has_one,
        primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}},
        through: {{through.id}}, source: {{source.id}}, through_association: {{through_is_association}},
        scope: {{scope}})]

      # Returns the associated record through an intermediate association.
      #
      # ```
      # record = owner.{{method_name.id}}
      # ```
      def {{method_name}} : {{class_name}}?
        if association_loaded?({{method_name.stringify}})
          get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
        else
          assert_association_can_lazy_load!({{method_name.stringify}}, {{options[:strict_loading]}})
          {% if through_is_association %}
            # Two IN-style queries (join rows, then the target) through the same
            # loader `includes` uses, so the lazy and preloaded results agree.
            _eager_batch_load([self] of Grant::Base, {{method_name.stringify}})
            get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
          {% else %}
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
            owner_key = {% if options[:primary_key] %}self.read_attribute({{primary_key_name}}){% else %}self.read_attribute(self.class.primary_name){% end %}
            result = {{class_name.id}}.first(sql, [owner_key])
            if result
              Grant::Logs::Association.debug { "Loaded has_one :through association - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [through: #{{{through.id.stringify}}}]" }
              _adopt_strict_loading(result, false)
            end
            result
          {% end %}
        end
      end

      # Returns the associated record through an intermediate association, raising if not found.
      def {{method_name}}! : {{class_name}}
        {{method_name}} || raise Grant::Querying::NotFound.new("No #{{{class_name.id.stringify}}} found through #{{{through.id.stringify}}} for #{self.class.name}")
      end

      def reset_{{method_name.id}} : Nil
        reset_association({{method_name.stringify}})
      end

      def reload_{{method_name.id}} : {{class_name.id}}?
        {% if through_is_association %}
          reset_association({{through.id.stringify}})
          reload_association({{method_name.stringify}})
        {% else %}
          reset_association({{method_name.stringify}})
        {% end %}
        {{method_name.id}}
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
      _grant_register_association({{method_name.id.stringify}}, :has_one, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}}, {{through.id.stringify}}, {{source.id.stringify}})
      _grant_register_reflection({{method_name.id.stringify}}, :has_one, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}},
        nil, nil, {{through.id.stringify}}, {{source.id.stringify}}, nil, nil, {{options[:inverse_of] == false}},
        {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)
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
    {% foreign_key_name = foreign_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% primary_key_name = primary_key.stringify.gsub(/:/, "").gsub(/"/, "") %}

    @[Grant::Relationship(target: {{class_name.id}}, type: :has_one,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}}, scope: {{scope}})]

    {% inverse_of = options[:inverse_of] %}

    def {{method_name}} : {{class_name}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      else
        assert_association_can_lazy_load!({{method_name.stringify}}, {{options[:strict_loading]}})
        owner_key = {% if options[:primary_key] %}self.read_attribute({{primary_key_name}}){% else %}self.read_attribute(self.class.primary_name){% end %}
        relation = {{class_name.id}}.where({{foreign_key_name}}, :eq, owner_key)
        {% if scope.is_a?(ProcLiteral) %}
          {% if scope.args.empty? %}
            relation = relation.{{scope.body}}
          {% else %}
            relation = {{scope}}.call(relation)
          {% end %}
        {% end %}
        result = relation.first
        set_loaded_association({{method_name.stringify}}, result)
        if result
          Grant::Logs::Association.debug { "Loaded has_one association - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [fk: #{{{foreign_key.id.stringify}}} = #{owner_key}]" }
          _adopt_strict_loading(result, false)
          {% if inverse_of %}
            result.set_loaded_association({{inverse_of.id.stringify}}, self)
          {% elsif options[:inverse_of] != false %}
            if detected_inverse = _association_inverse({{method_name.stringify}})
              result.set_loaded_association(detected_inverse, self)
            end
          {% end %}
        end
        result
      end
    end

    def {{method_name}}! : {{class_name}}
      was_loaded = association_loaded?({{method_name.stringify}})
      result = {{method_name}}
      return result if result
      raise Grant::Querying::NotFound.new("No {{class_name.id}} found") if was_loaded
      owner_value = {% if options[:primary_key] %}self.read_attribute({{primary_key_name}}){% else %}self.read_attribute(self.class.primary_name){% end %}
      raise Grant::Querying::NotFound.new("No {{class_name.id}} found where #{{{foreign_key_name}}} = #{owner_value}")
    end

    # Assigns the child. On a saved owner the child is saved now and the
    # previous child is displaced the way `dependent:` says (destroyed,
    # deleted, or its foreign key cleared), in one transaction. On an unsaved
    # owner the child waits for its first save.
    def {{method_name}}=(child : {{class_name.id}}?)
      if persisted?
        current = {{method_name}}
        owner_key = {% if options[:primary_key] %}self.read_attribute({{primary_key_name}}){% else %}self.read_attribute(self.class.primary_name){% end %}
        Grant::Associations::HasOneWriter.replace(self, {{method_name.stringify}}, current, child, {{foreign_key_name}}, owner_key, {{options[:dependent].is_a?(SymbolLiteral) ? options[:dependent] : nil}})
      end
      _grant_assign_{{method_name.id}}(child)
    end

    # Points *child* at this record and makes it the loaded target, in memory.
    protected def _grant_assign_{{method_name.id}}(child : {{class_name.id}}?)
      if child
        if owner_key = {% if options[:primary_key] %}self.read_attribute({{primary_key_name}}){% else %}self.read_attribute(self.class.primary_name){% end %}
          child.set_attributes({ {{foreign_key_name}} => owner_key })
        end
      end
      set_loaded_association({{method_name.stringify}}, child)
    end

    _grant_define_has_one_builders({{method_name}}, {{class_name}}, {{foreign_key_name}}, {{options[:dependent]}})

    def reset_{{method_name.id}} : Nil
      reset_association({{method_name.stringify}})
    end

    def reload_{{method_name.id}} : {{class_name.id}}?
      reload_association({{method_name.stringify}})
      {{method_name.id}}
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
    _grant_register_reflection({{method_name.id.stringify}}, :has_one, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}},
      nil, nil, nil, nil, {{options[:dependent]}}, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    Grant::Dependent.check_dependent_option(:has_one, {{method_name}}, {{options[:dependent]}})

    # Handle dependent option
    {% if options[:dependent] && scope %}
      _grant_scoped_dependent({{method_name.id}}, :has_one, {{options[:dependent]}}, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}}, {{scope}})
    {% elsif options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        setup_dependent_destroy({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :delete %}
        setup_dependent_delete_all({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :nullify %}
        setup_dependent_nullify({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :restrict || options[:dependent] == :restrict_with_error %}
        setup_dependent_restrict({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :restrict_with_exception %}
        setup_dependent_restrict_with_exception({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :destroy_async %}
        setup_dependent_destroy_async({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% end %}
    {% end %}

    # Stage assigned has_one records and persist them through the owner's save.
    setup_autosave({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key_name}}, {{options[:primary_key] ? primary_key_name : nil}}, {{options[:autosave]}}, {{options[:validate]}}, {{options[:index_errors]}})
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
  # Common irregular plurals are supported. Pass `singular:` when an association
  # name has a project-specific or less common singular form.
  #
  # Options:
  #
  # * `class_name:` — target class when it differs from the inferred name
  #   (always wins over the inferred singular name; required for irregular
  #   plurals).
  # * `singular:` — explicit singular stem for the generated `<singular>_ids`
  #   reader and writer.
  # * `foreign_key:` — the FK column on the target (default
  #   `"<this_model>_id"`).
  # * `primary_key:` — the key on this model the FK references (default `"id"`).
  # * `through:` — a join model/table for many-to-many (e.g.
  #   `has_many :tags, through: :taggings`); pair with `source:` to name the
  #   association on the join model whose target is collected. The through
  #   association may itself be a `through:` association (nested, read-only),
  #   read with one statement.
  # * `source_type:` — with `through:` and a polymorphic `belongs_to` source, the
  #   class the target is read as (`source: :taggable, source_type: Post`). The
  #   join adds `taggable_type = 'Post'`, and `<<` / `delete` write that type.
  # * `as:` — make this the `has_many` side of a polymorphic association.
  # * `dependent:` / `inverse_of:` / `autosave:` — see
  #   `Grant::AssociationOptions`. `dependent:` also picks how `delete`,
  #   `delete_all` and `clear` remove records (`nullify` when absent).
  # * `before_add:` / `after_add:` / `before_remove:` / `after_remove:` — a
  #   method name called on the owner with the record, a typed proc
  #   `->(owner : User, post : Post) { ... }`, or an array of them. A `before_`
  #   hook that returns `false` (or raises) stops the operation. Hooks run per
  #   record for `<<`, `build`, `create`, `delete`, `destroy` and `<singular>_ids=`,
  #   never for `delete_all`.
  #
  # ```
  # class User < Grant::Base
  #   connection sqlite
  #   column id : Int64, primary: true
  #   has_many :posts, after_add: :log_post
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
    _grant_check_association_options(:has_many, {{model}}, {{options.keys.map(&.stringify)}} of String, {{options[:through] ? true : false}}, {{options[:source_type] ? true : false}})
    {% if model.is_a? TypeDeclaration %}
      {% hoisted_name = model.var %}
    {% else %}
      {% hoisted_name = model.id %}
    {% end %}
    {% if options[:singular] %}
      {% singular_name = options[:singular].stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% else %}
      {% association_name = hoisted_name.id.stringify %}
      {% if association_name == "children" %}
        {% singular_name = "child" %}
      {% elsif association_name == "people" %}
        {% singular_name = "person" %}
      {% elsif association_name == "mice" %}
        {% singular_name = "mouse" %}
      {% elsif association_name == "geese" %}
        {% singular_name = "goose" %}
      {% elsif association_name == "men" %}
        {% singular_name = "man" %}
      {% elsif association_name == "women" %}
        {% singular_name = "woman" %}
      {% elsif association_name == "teeth" %}
        {% singular_name = "tooth" %}
      {% elsif association_name == "feet" %}
        {% singular_name = "foot" %}
      {% elsif association_name == "quizzes" %}
        {% singular_name = "quiz" %}
      {% elsif association_name.ends_with?("ies") %}
        {% singular_name = association_name[0...-3] + "y" %}
      {% elsif association_name.ends_with?("ses") || association_name.ends_with?("xes") || association_name.ends_with?("zes") || association_name.ends_with?("ches") || association_name.ends_with?("shes") %}
        {% singular_name = association_name[0...-2] %}
      {% elsif association_name.ends_with?("s") && !association_name.ends_with?("ss") %}
        {% singular_name = association_name[0...-1] %}
      {% else %}
        {% singular_name = association_name %}
      {% end %}
    {% end %}
    {% if options[:foreign_key].is_a?(TupleLiteral) || options[:foreign_key].is_a?(ArrayLiteral) || options[:query_constraints] %}
      composite_has_many({{model}}, {{scope}}, {% for key, value in options %}{{key.id}}: {{value}}, {% end %})
    {% elsif options[:as] %}
      has_many_polymorphic({{model}}, {{options[:as]}}, {% for key, value in options %}{{key.id}}: {{value}}, {% end %})
      _grant_define_ids_accessors({{hoisted_name}}, {{singular_name}}, false, true)
    {% else %}
    {% if model.is_a? TypeDeclaration %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% if options[:class_name] %}
        # Explicit override always wins (required for irregular plurals).
        {% class_name = options[:class_name] %}
      {% elsif options[:source_type] %}
        # A polymorphic source is read as the class `source_type:` names.
        {% class_name = options[:source_type] %}
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
    {% foreign_key_name = foreign_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% primary_key_name = primary_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% through = options[:through] %}
    {% inverse_of = options[:inverse_of] %}
    # `source:` names the association on the join model whose target is collected
    # for `:through`. When absent it defaults to the singular form of method_name.
    {% source = options[:source] %}
    {% source = options[:source] || singular_name.id %}
    @[Grant::Relationship(target: {{class_name.id}}, through: {{through.id}}, type: :has_many,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}}, source: {{source.id}},
      owner_primary_key: {{primary_key.id}}, scope: {{scope}})]
    def {{method_name.id}}
      {% if scope %}
        {% if scope.args.empty? %}
          scope_proc = ->(q : Grant::Query::Builder({{class_name.id}})) { q.{{scope.body}} }
        {% else %}
          scope_proc = {{scope}}
        {% end %}
      {% else %}
        scope_proc = nil
      {% end %}
      {% if through && source %}
        {% join_pk = "#{source.id}_id" %}
      {% else %}
        {% join_pk = primary_key %}
      {% end %}
      loaded_records = nil.as(Array({{class_name.id}})?)
      if association_loaded?({{method_name.stringify}})
        loaded_data = get_loaded_association({{method_name.stringify}})
        if loaded_data.is_a?(Array(Grant::Base))
          loaded_records = loaded_data.map(&.as({{class_name.id}}))
        end
      end
      {% if through %}
        through_delete_all = -> : Int64 { self.{{through.id}}.delete_all }
      {% else %}
        through_delete_all = nil
      {% end %}
      unless association_loaded?({{method_name.stringify}})
        Grant::Logs::Association.debug { "Created has_many association collection - #{self.class.name}.#{{{method_name.stringify}}} [#{{{class_name.id.stringify}}}] [fk: #{{{foreign_key.id.stringify}}}]#{{{through ? " [through: " + through.id.stringify + "]" : ""}}}" }
      end
      {% if options[:before_add] || options[:after_add] || options[:before_remove] || options[:after_remove] %}
        callbacks = Grant::AssociationCallbacks({{class_name.id}}).new(
          {% if options[:before_add] %}before_add: _grant_association_hook({{options[:before_add]}}, {{class_name}}),{% end %}
          {% if options[:after_add] %}after_add: _grant_association_hook({{options[:after_add]}}, {{class_name}}),{% end %}
          {% if options[:before_remove] %}before_remove: _grant_association_hook({{options[:before_remove]}}, {{class_name}}),{% end %}
          {% if options[:after_remove] %}after_remove: _grant_association_hook({{options[:after_remove]}}, {{class_name}}),{% end %}
        )
      {% else %}
        callbacks = nil
      {% end %}
      {% if through %}
        {% if options[:source_type] %}
          through_writer = -> { self.{{through.id}}.through_writer({{source.id.stringify}}, {{options[:source_type]}}.polymorphic_name) }
        {% else %}
          through_writer = -> { self.{{through.id}}.through_writer({{source.id.stringify}}) }
        {% end %}
      {% else %}
        through_writer = nil
      {% end %}
      {% if through %}
        # Targets built or appended before the owner is saved wait here; the
        # owner's `after_save` inserts their join rows.
        pending = (@_{{method_name.id}}_pending_through ||= [] of {{class_name.id}})
      {% else %}
        pending = nil
      {% end %}
      Grant::AssociationCollection(self, {{class_name.id}}).new(
        self, {{foreign_key_name}}, {{through}}, {{options[:primary_key] ? primary_key : nil}},
        {{inverse_of ? inverse_of : nil}}, scope_proc, {{method_name.stringify}}, loaded_records, through_delete_all,
        {{through ? source.id.stringify : nil}},
        strict_loading_option: {{options[:strict_loading]}},
        automatic_inverse: {{options[:inverse_of] != false && !through}},
        dependent: {{options[:dependent].is_a?(SymbolLiteral) ? options[:dependent] : nil}},
        through_writer: through_writer,
        callbacks: callbacks,
        pending: pending,
        counter_column: {% if options[:counter_cache] %}{% if options[:counter_cache] == true %}{{method_name.id.stringify + "_count"}}{% else %}{{options[:counter_cache].id.stringify}}{% end %}{% else %}nil{% end %}
      )
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{method_name.stringify}})
    end

    def reload_{{method_name.id}}
      {% if through %}
        # A preloaded through association would hand back stale join rows.
        reset_association({{through.id.stringify}})
      {% end %}
      reload_association({{method_name.stringify}})
      {{method_name.id}}
    end

    _grant_define_ids_accessors({{method_name}}, {{singular_name}}, {{through ? true : false}}, false)

    {% if through %}
    @_{{method_name.id}}_pending_through : Array({{class_name.id}})? = nil

    # Inserts the join rows of targets that were built or appended while the
    # owner was unsaved.
    after_save do
      if (waiting = @_{{method_name.id}}_pending_through) && !waiting.empty?
        {{method_name.id}}.save_pending
      end
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
    _grant_register_association({{method_name.id.stringify}}, :has_many, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}}, {{through ? through.id.stringify : nil}}, {{through ? source.id.stringify : nil}})
    _grant_register_reflection({{method_name.id.stringify}}, :has_many, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key.id.stringify}},
      nil, nil, {{through ? through.id.stringify : nil}}, {{through ? source.id.stringify : nil}}, {{options[:dependent]}}, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    Grant::Dependent.check_dependent_option(:has_many, {{method_name}}, {{options[:dependent]}})

    # Handle dependent option
    {% if options[:dependent] && through %}
      setup_dependent_through({{method_name.id}}, {{through.id}}, {{options[:dependent]}})
    {% elsif options[:dependent] && scope %}
      _grant_scoped_dependent({{method_name.id}}, :has_many, {{options[:dependent]}}, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}}, {{scope}})
    {% elsif options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        setup_dependent_destroy({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :delete_all %}
        setup_dependent_delete_all({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :nullify %}
        setup_dependent_nullify({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :restrict || options[:dependent] == :restrict_with_error %}
        setup_dependent_restrict({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :restrict_with_exception %}
        setup_dependent_restrict_with_exception({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% elsif options[:dependent] == :destroy_async %}
        setup_dependent_destroy_async({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{primary_key_name}})
      {% end %}
    {% end %}

    # Handle autosave
    {% unless through %}
      # Stage assigned has_many records and persist them through the owner's save.
      setup_autosave({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key_name}}, {{options[:primary_key] ? primary_key_name : nil}}, {{options[:autosave]}}, {{options[:validate]}}, {{options[:index_errors]}})

      # Replaces the collection. On a saved owner this writes now, in one
      # transaction: records that left the set follow the association's
      # `dependent:` strategy and each new record is saved. On an unsaved owner
      # the records wait for its first save.
      def {{method_name.id}}=(records : Array({{class_name.id}}))
        if persisted?
          {{method_name.id}}.replace(records)
          return records
        end
        owner_key = self.read_attribute({{primary_key_name}})
        if owner_key
          records.each do |record|
            record.set_attributes({ {{foreign_key_name}} => owner_key })
          end
        end
        set_loaded_association({{method_name.stringify}}, records.map(&.as(Grant::Base)))
      end
    {% else %}
      # Replaces the collection: removes the targets that left the set and
      # inserts the join rows of the new ones (one INSERT, one DELETE).
      def {{method_name.id}}=(records : Array({{class_name.id}}))
        {{method_name.id}}.replace(records)
        records
      end
    {% end %}
    {% end %}
  end

  # Builds the `Proc(Target, Bool)` for one `before_add`/`after_add`/
  # `before_remove`/`after_remove` option. *value* is a method name (a `Symbol`
  # called on the owner with the record), a typed proc `->(owner : User, post : Post) { }`,
  # or an `Array` of those. The proc returns `false` when any hook did, which
  # makes a `before_` hook veto the operation.
  macro _grant_association_hook(value, target_class)
    {% hooks = value.is_a?(ArrayLiteral) ? value : [value] %}
    ->(record : {{target_class.id}}) : Bool {
      {% for hook in hooks %}
        {% if hook.is_a?(SymbolLiteral) %}
          return false if self.{{hook.id}}(record) == false
        {% else %}
          return false if ({{hook}}).call(self, record) == false
        {% end %}
      {% end %}
      true
    }
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

  # Records the full `Grant::Reflection` of an association so
  # `reflect_on_association` can describe it. Emitted by every association
  # macro, polymorphic ones included.
  macro _grant_register_reflection(name, macro_name, target_class, foreign_key, primary_key, type_column, polymorphic_as, through, source, dependent, inverse_of, inverse_disabled, scoped, polymorphic, strict_loading, option_keys, option_values)
    Grant::AssociationRegistry.register_reflection(
      Grant::Reflection.new(
        {{@type.name.stringify}}, {{name}}, {{macro_name}}, {{target_class.id}}, {{target_class.id}}.name,
        {{foreign_key}}, {{primary_key}},
        foreign_type: {{type_column}}, polymorphic_as: {{polymorphic_as}},
        through: {{through}}, source: {{source}}, dependent: {{dependent}},
        inverse_of_name: {{inverse_of}}, inverse_disabled: {{inverse_disabled}},
        scoped: {{scoped}}, polymorphic: {{polymorphic}}, strict_loading_option: {{strict_loading}},
        options: { {% for key, index in option_keys %}{{key}} => {{option_values[index]}}, {% end %} } of String => String
      ),
      {{@type}}
    )
  end

  # Registers association metadata into the runtime `AssociationRegistry` so that
  # `Grant::AssociationRegistry.get(model_class, name)` reflection works without
  # recompilation. Emitted by each association macro. The registration call is
  # placed at class-body level so it executes once when the model class loads.
  macro _grant_register_association(name, type, target_class, foreign_key, primary_key, through, source = nil)
    Grant::AssociationRegistry.register(
      {{@type.name.stringify}},
      {{name}},
      {
        type:         {{type}},
        target_class: {{target_class.id}},
        foreign_key:  {{foreign_key}},
        primary_key:  {{primary_key}},
        through:      {{through}},
        source:       {{source}},
      }
    )
    {% if type == :belongs_to || (type == :has_one && through.nil?) || (type == :has_many && through.nil?) %}
      Grant::AssociationRegistry.register_writer(
        {{@type.name.stringify}}, {{name}},
        ->(record : Grant::Base, value : Grant::AssociationRegistry::AssociationValue) : Bool {
          owner = record.as({{@type}})
          {% if type == :belongs_to || type == :has_one %}
            if value.nil?
              owner.{{name.id}} = nil
              true
            elsif associated = value.as?({{target_class.id}})
              owner.{{name.id}} = associated
              true
            else
              false
            end
          {% elsif type == :has_many %}
            if value.nil?
              owner.{{name.id}} = [] of {{target_class.id}}
              true
            elsif associated = value.as?(Array(Grant::Base))
              if associated.all? { |item| item.is_a?({{target_class.id}}) }
                typed_associated = associated.map(&.as({{target_class.id}}))
                owner.{{name.id}} = typed_associated
                true
              else
                false
              end
            else
              false
            end
          {% end %}
        }
      )
    {% end %}
  end
end

require "./associations/option_validation"
require "./associations/singular_builders"
require "./associations/collection_accessors"
require "./associations/has_one_writer"
require "./associations/through_preload"
require "./associations/habtm"
require "./associations/composite_foreign_key"
