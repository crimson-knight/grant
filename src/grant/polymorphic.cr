# Polymorphic associations for Grant — one association that can point at rows in
# several different tables.
#
# A polymorphic `belongs_to` stores **two** columns: an `*_id` foreign key and a
# `*_type` string holding the target class name. The matching `has_many` /
# `has_one` on the other side is declared with `as:`. You normally reach these
# generated methods through the regular `belongs_to`/`has_many`/`has_one` macros
# (`polymorphic: true` and `as:` respectively); the macros here implement them.
#
# For `belongs_to :commentable, polymorphic: true` Grant generates:
#
# * a `commentable_id : Int64?` column and a `commentable_type : String?` column,
# * `#commentable : Grant::Base?` — loads the target by resolving `*_type`/`*_id`,
# * `#commentable! : Grant::Base` — same, raising `Grant::Querying::NotFound`,
# * `#commentable=(record : Grant::Base?)` — sets both columns from *record*
#   (or clears both when given `nil`),
# * `#commentable_proxy : PolymorphicProxy` — a lazy loader you can keep around.
#
# Targets must register themselves for runtime resolution by calling
# `register_polymorphic_type` (the side using `as:` does this automatically).
#
# ```
# class Comment < Grant::Base
#   connection sqlite
#   column id : Int64, primary: true
#   column body : String
#   belongs_to :commentable, polymorphic: true # commentable_id + commentable_type
# end
#
# class Post < Grant::Base
#   has_many :comments, as: :commentable
# end
#
# class Photo < Grant::Base
#   has_many :comments, as: :commentable
# end
#
# comment = Comment.find!(1)
# comment.commentable        # => Post or Photo (whichever commentable_type names)
# comment.commentable = post # sets commentable_id = post.id, commentable_type = "Post"
# post.comments.to_a         # comments where commentable_type = "Post"
# ```
module Grant::Polymorphic
  # Compile-time storage for registered types
  REGISTERED_TYPES = {} of String => ASTNode

  # Records *klass* under the string *name* in the compile-time registry, so
  # `load_polymorphic` can map a stored `*_type` string back to a class. Called
  # for you by the zero-arg `register_polymorphic_type` (see below).
  macro register_polymorphic_type(name, klass)
    {% REGISTERED_TYPES[name] = klass %}
  end

  # Generate the polymorphic loader after all types are registered
  macro finished
    # Resolves a polymorphic target from its stored `*_type` string and `*_id`,
    # returning the record or `nil` (unknown/unregistered type or missing row).
    #
    # ```
    # Grant::Polymorphic.load_polymorphic("Post", 1_i64) # => Post? with id 1
    # ```
    def self.load_polymorphic(type_name : String, id : Grant::Columns::Type) : Grant::Base?
      # A stored key is never an array; narrowing keeps `find` on its
      # single-key overload instead of the `find(ids : Array)` one.
      return nil if id.is_a?(Array)

      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          nil
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          nil
        {% else %}
          {{klass}}.find(id)
        {% end %}
      {% end %}
      else
        nil
      end
    end

    # Updates a counter on a polymorphic target through a compile-time
    # dispatch table, retaining each target model's primary-key and adapter
    # behavior even though the association is typed as Grant::Base.
    def self.update_counter(type_name : String, id : Int64, column_name : String, amount : Int32) : Nil
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          nil
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          nil
        {% else %}
          quoted_column = {{klass}}.quote(column_name)
          operator = amount > 0 ? "+" : "-"
          {{klass}}.where({{klass}}.primary_name, :eq, id)
            .update_all("#{quoted_column} = #{quoted_column} #{operator} #{amount.abs}")
          nil
        {% end %}
      {% end %}
      else
        nil
      end
    end

    # Touches a polymorphic target through concrete model dispatch so its
    # timestamp columns and primary key are resolved at compile time.
    def self.touch_target(type_name : String, id : Int64, fields : Array(String)) : Nil
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          nil
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          nil
        {% else %}
          if {{klass}}.fields.includes?("updated_at")
            time = Time.local(Grant.settings.default_timezone).at_beginning_of_second
            field_names = ["updated_at"] + fields
            parameters = [] of DB::Any
            field_names.each { parameters << time }
            parameters << id
            quoted_primary_key = {{klass}}.quote({{klass}}.primary_name)
            where_clause = "#{quoted_primary_key} = ?"
            {{klass}}.adapter.update_with_where({{klass}}.table_name, field_names, parameters, where_clause)
          end
          nil
        {% end %}
      {% end %}
      else
        nil
      end
    end

    # Loads one batch of targets that share a stored polymorphic type with one
    # IN query (chunked above `Grant.settings.in_clause_limit`). The query runs
    # through each target model's current scope, including tenant and default
    # scopes.
    def self.load_polymorphic_batch(type_name : String, primary_key : String?, ids : Array(Grant::Columns::Type)) : Array(Grant::Base)
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          [] of Grant::Base
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          [] of Grant::Base
        {% else %}
          return [] of Grant::Base if ids.empty?
          Grant::AssociationLoader.enable({{klass}})
          key_column = primary_key || {{klass}}.primary_name || raise Grant::Querying::MissingPrimaryKeyError.new("#{{{klass}}.name} has no primary key")
          Grant::AssociationLoader.where_in({{klass}}.current_scope, key_column, ids).select.map(&.as(Grant::Base))
        {% end %}
      {% end %}
      else
        [] of Grant::Base
      end
    end

    # Adjusts a numeric counter column on a polymorphic target without losing
    # the concrete model's adapter, default scope, or tenancy behavior.
    def self.adjust_polymorphic_counter_cache(type_name : String, id : Grant::Columns::Type, column : String, delta : Int32) : Nil
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          nil
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          nil
        {% else %}
          quoted_column = {{klass}}.quote(column)
          {{klass}}.where({{klass}}.primary_name, :eq, id)
            .update_all("#{quoted_column} = COALESCE(#{quoted_column}, 0) + #{delta}")
        {% end %}
      {% end %}
      else
        nil
      end
      nil
    end

    # Touches a polymorphic target through its model-scoped relation, avoiding
    # record hydration while preserving the model's current scopes and tenancy.
    def self.touch_polymorphic_target(type_name : String, id : Grant::Columns::Type, column : String?) : Bool
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          false
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          false
        {% else %}
          if {{klass}}.fields.includes?("updated_at")
            relation = {{klass}}.where({{klass}}.primary_name, :eq, id)
            if column
              relation.touch_all(column.to_sym) > 0
            else
              relation.touch_all > 0
            end
          else
            false
          end
        {% end %}
      {% end %}
      else
        false
      end
    end
    
    # Like `load_polymorphic`, but raises `Grant::Querying::NotFound` instead of
    # returning `nil`.
    #
    # ```
    # Grant::Polymorphic.load_polymorphic!("Post", 1_i64) # => Post (raises if absent)
    # ```
    def self.load_polymorphic!(type_name : String, id : Grant::Columns::Type) : Grant::Base
      load_polymorphic(type_name, id) || raise Grant::Querying::NotFound.new("No #{type_name} found with id #{id}")
    end

    # True when *type_name* names a class registered for polymorphic resolution.
    #
    # ```
    # Grant::Polymorphic.registered_type?("Post")    # => true
    # Grant::Polymorphic.registered_type?("Unknown") # => false
    # ```
    def self.registered_type?(type_name : String) : Bool
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name == "Grant::Base" || name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          false
        {% elsif (resolved = klass.resolve?) && resolved.abstract? %}
          false
        {% else %}
          true
        {% end %}
      {% end %}
      else
        false
      end
    end

  end

  # The primary key value of *record*, whatever its model's key column is
  # called (`nil` for a model without a primary key or an unsaved record).
  def self.primary_key_of(record : Grant::Base) : Grant::Columns::Type
    if column = record.class.primary_name
      record.read_attribute(column)
    end
  end

  # Converts a target's primary key to the type of the polymorphic foreign key
  # column: numeric keys widen to `Int64`, any key can be stored in a `String`
  # column, and a key already of the column's type is kept as is.
  def self.coerce_key(value : Grant::Columns::Type, target : T.class) : T forall T
    return value if value.is_a?(T)
    {% if T.union_types.includes?(String) %}
      return value.to_s
    {% end %}
    {% if T.union_types.includes?(Int64) %}
      return value.to_i64 if value.is_a?(Int32)
    {% end %}
    raise ArgumentError.new("Polymorphic associations require numeric primary keys for a #{T} foreign key column, got #{value.class}; declare the column as a String or UUID with `foreign_key: name_id : String?`")
  end

  # Lazy loader for a polymorphic `belongs_to` target, returned by the generated
  # `#<name>_proxy` method. Holds the raw `*_type` / `*_id` values and resolves
  # them to a record on demand, without loading the row until you ask.
  #
  # ```
  # proxy = comment.commentable_proxy
  # proxy.present? # => true when both type and id are set
  # proxy.load     # => Grant::Base? (the Post/Photo/... or nil)
  # proxy.load!    # => Grant::Base  (raises Grant::Querying::NotFound if unset/missing)
  # ```
  struct PolymorphicProxy
    # The stored target class name (the `*_type` column), or `nil`.
    getter type : String?
    # The stored target id (the `*_id` column), or `nil`.
    getter id : Grant::Columns::Type

    def initialize(@type : String?, @id : Grant::Columns::Type)
    end

    # Resolves and returns the target record, or `nil` when the type/id are
    # unset or no matching row exists.
    #
    # ```
    # comment.commentable_proxy.load # => Post? / Photo? / nil
    # ```
    def load : Grant::Base?
      if type = @type
        if id = @id
          return Grant::Polymorphic.load_polymorphic(type, id)
        end
      end
      nil
    end

    # Resolves and returns the target record, raising `Grant::Querying::NotFound`
    # when the association is unset or the row is missing.
    #
    # ```
    # comment.commentable_proxy.load! # => Grant::Base (raises if absent)
    # ```
    def load! : Grant::Base
      type = @type || raise Grant::Querying::NotFound.new("Polymorphic association not set")
      id = @id || raise Grant::Querying::NotFound.new("Polymorphic association not set")
      Grant::Polymorphic.load_polymorphic!(type, id)
    end

    # True when both the type and id are set (so a target can be resolved).
    #
    # ```
    # comment.commentable_proxy.present? # => false until you assign a target
    # ```
    def present? : Bool
      !@type.nil? && !@id.nil?
    end

    # Re-resolves and returns the target record (an alias for `load` that
    # re-queries the database).
    def reload : Grant::Base?
      load
    end
  end

  # Implements the polymorphic `belongs_to` (invoked by
  # `belongs_to :name, polymorphic: true`).
  #
  # For `name == :commentable` this generates the `commentable_id : Int64?` and
  # `commentable_type : String?` columns plus `#commentable`, `#commentable!`,
  # `#commentable=`, and `#commentable_proxy`. Unless `optional: true` is given,
  # it also adds a presence validation requiring both columns to be set.
  #
  # Options: `type_column:` / `foreign_key:` / `primary_key:` override the
  # derived column names, and `optional: true` skips the presence validation.
  # Give `foreign_key:` a typed declaration (`foreign_key: commentable_id : String?`)
  # when the targets use UUID or String keys. The stored type is the target's
  # `polymorphic_name` (its class name, or the STI root's).
  #
  # ```
  # class Comment < Grant::Base
  #   belongs_to :commentable, polymorphic: true
  # end
  #
  # comment = Comment.new
  # comment.commentable = some_post # sets *_id and *_type
  # comment.commentable             # => some_post (resolved via *_type/*_id)
  # ```
  macro belongs_to_polymorphic(name, **options)
    # Extract the type column name
    {% type_column = options[:type_column] || name.id.stringify + "_type" %}
    {% foreign_key = options[:foreign_key] || name.id.stringify + "_id" %}
    # Without `primary_key:` each target is matched on its own primary key.
    {% primary_key = options[:primary_key] %}
    {% primary_key_name = primary_key ? primary_key.id.stringify : nil %}

    {% if options[:counter_cache] %}
      {% counter_option = options[:counter_cache] %}
      {% counter_active = true %}
      {% if counter_option.is_a?(NamedTupleLiteral) %}
        {% counter_active = counter_option[:active] == false ? false : true %}
        {% counter_option = counter_option[:column] || true %}
      {% end %}
      {% if counter_option.is_a?(SymbolLiteral) %}
        {% counter_column = counter_option.id.stringify %}
      {% elsif counter_option.is_a?(StringLiteral) %}
        {% counter_column = counter_option.id.stringify %}
      {% else %}
        {% counter_column = "Grant::CounterCache.default_column(#{@type.name.stringify})".id %}
      {% end %}
      {% if counter_active %}
      after_create do
        foreign_id = self.read_attribute({{foreign_key.id.stringify}})
        type_name = self.read_attribute({{type_column.id.stringify}})
        if !foreign_id.nil? && type_name.is_a?(String)
          Grant::Polymorphic.adjust_polymorphic_counter_cache(type_name, foreign_id, {{counter_column}}, 1)
        end
      end

      before_update do
        if attribute_changed?({{foreign_key.id.stringify}}) || attribute_changed?({{type_column.id.stringify}})
          old_id = attribute_was({{foreign_key.id.stringify}})
          old_type = attribute_was({{type_column.id.stringify}})
          new_id = self.read_attribute({{foreign_key.id.stringify}})
          new_type = self.read_attribute({{type_column.id.stringify}})

          if !old_id.nil? && old_type.is_a?(String)
            Grant::Polymorphic.adjust_polymorphic_counter_cache(old_type, old_id, {{counter_column}}, -1)
          end
          if !new_id.nil? && new_type.is_a?(String)
            Grant::Polymorphic.adjust_polymorphic_counter_cache(new_type, new_id, {{counter_column}}, 1)
          end
        end
      end

      after_destroy do
        foreign_id = self.read_attribute({{foreign_key.id.stringify}})
        type_name = self.read_attribute({{type_column.id.stringify}})
        if !foreign_id.nil? && type_name.is_a?(String)
          Grant::Polymorphic.adjust_polymorphic_counter_cache(type_name, foreign_id, {{counter_column}}, -1)
        end
      end
      {% end %}
    {% end %}

    {% if options[:touch] %}
      {% touch_column = options[:touch] == true ? nil : options[:touch] %}
      after_save do
        foreign_id = self.read_attribute({{foreign_key.id.stringify}})
        type_name = self.read_attribute({{type_column.id.stringify}})
        if !foreign_id.nil? && type_name.is_a?(String)
          Grant::Polymorphic.touch_polymorphic_target(type_name, foreign_id, {{touch_column ? touch_column.id.stringify : nil}})
        end
      end
      after_destroy do
        foreign_id = self.read_attribute({{foreign_key.id.stringify}})
        type_name = self.read_attribute({{type_column.id.stringify}})
        if !foreign_id.nil? && type_name.is_a?(String)
          Grant::Polymorphic.touch_polymorphic_target(type_name, foreign_id, {{touch_column ? touch_column.id.stringify : nil}})
        end
      end
    {% end %}

    # Define the foreign key column (declared by `belongs_to` itself when the
    # caller gave a typed `foreign_key:`)
    {% unless options[:foreign_key_declared] %}
      column {{foreign_key.id}} : Int64?
    {% end %}

    # Define the type column
    column {{type_column.id}} : String?

    # Define proxy getter
    def {{name.id}}_proxy : Grant::Polymorphic::PolymorphicProxy
      Grant::Polymorphic::PolymorphicProxy.new(@{{type_column.id}}, @{{foreign_key.id}})
    end

    # Define getter method
    @[Grant::Relationship(target: Grant::Base, type: :belongs_to, polymorphic: true,
      foreign_key: {{foreign_key.id.stringify}}, type_column: {{type_column.id.stringify}},
      primary_key: {{primary_key_name}})]
    def {{name.id}} : Grant::Base?
      if association_loaded?({{name.id.stringify}})
        get_loaded_association({{name.id.stringify}}).as(Grant::Base?)
      else
        assert_association_can_lazy_load!({{name.id.stringify}}, {{options[:strict_loading]}})
        target = {{name.id}}_proxy.load
        _adopt_strict_loading(target, false)
        target
      end
    end

    # Define bang getter
    def {{name.id}}! : Grant::Base
      {{name.id}} || raise Grant::Querying::NotFound.new("Polymorphic association not found")
    end

    # Define setter method
    def {{name.id}}=(record : Grant::Base?)
      if record.nil?
        clear_nullable_attribute({{foreign_key.id.stringify}})
        clear_nullable_attribute({{type_column.id.stringify}})
      else
        primary_key_value = {% if primary_key %}record.read_attribute({{primary_key_name}}){% else %}Grant::Polymorphic.primary_key_of(record){% end %}
        if primary_key_value.nil?
          clear_nullable_attribute({{foreign_key.id.stringify}})
        else
          self.{{foreign_key.id}} = Grant::Polymorphic.coerce_key(primary_key_value, typeof(self.{{foreign_key.id}}))
        end
        self.{{type_column.id}} = record.class.polymorphic_name
      end
      set_loaded_association({{name.id.stringify}}, record)
    end

    def reset_{{name.id}} : Nil
      reset_association({{name.id.stringify}})
    end

    def reload_{{name.id}} : Grant::Base?
      reset_association({{name.id.stringify}})
      target = {{name.id}}_proxy.load
      set_loaded_association({{name.id.stringify}}, target)
      target
    end

    # Reached from mass assignment through `_grant_assign_association`.
    def _grant_write_assoc_{{name.id}}(value : Grant::AssociationRegistry::AssociationValue) : Bool
      if value.nil?
        self.{{name.id}} = nil
        true
      elsif associated = value.as?(Grant::Base)
        self.{{name.id}} = associated
        true
      else
        false
      end
    end

    _grant_register_reflection({{name.id.stringify}}, :belongs_to, Grant::Base, {{foreign_key.id.stringify}}, {{primary_key ? primary_key_name : "id"}},
      {{type_column.id.stringify}}, nil, nil, nil, nil, nil, false, false, true, {{options[:strict_loading]}},
      {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    # Store association metadata
    class_getter _{{name.id}}_association_meta = {
      type: :belongs_to,
      polymorphic: true,
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}},
      primary_key: {{primary_key ? primary_key_name : "id"}}
    }

    # Handle optional validation
    {% unless options[:optional] %}
      validate "{{name.id}} must be present" do |instance|
        !instance.{{foreign_key.id}}.nil? && !instance.{{type_column.id}}.nil?
      end
    {% end %}

  end

  # Implements the polymorphic `has_many` (invoked by
  # `has_many :name, as: :poly_as`).
  #
  # Generates `#<name>` returning a `Grant::AssociationCollection` of records
  # whose `<poly_as>_type` equals this model's `polymorphic_name` and whose
  # `<poly_as>_id` equals this record's primary key; the type predicate is part
  # of the SQL, so counts, `where`, and `exists?` never load rows. The
  # association is preloadable (`includes(:comments)`) and supports every
  # `dependent:` option.
  #
  # Options: `class_name:` sets the target class, `foreign_key:` / `type_column:`
  # override the derived `<poly_as>_id` / `<poly_as>_type` column names.
  # `dependent:` also picks how `delete`, `delete_all` and `clear` remove
  # records, and `before_add:` / `after_add:` / `before_remove:` /
  # `after_remove:` work as on `has_many`.
  #
  # ```
  # class Post < Grant::Base
  #   has_many :comments, as: :commentable, dependent: :destroy
  # end
  #
  # post.comments.to_a # comments where commentable_type="Post" AND commentable_id=post.id
  # ```
  macro has_many_polymorphic(name, poly_as, **options)
    {% foreign_key = options[:foreign_key] || (poly_as.id.stringify + "_id") %}
    {% type_column = options[:type_column] || (poly_as.id.stringify + "_type") %}
    {% primary_key = options[:primary_key] || "id" %}
    {% primary_key_name = primary_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% inverse_of = options[:inverse_of] %}
    {% if name.is_a? TypeDeclaration %}
      {% method_name = name.var %}
      {% class_name = name.type %}
    {% else %}
      {% method_name = name.id %}
      {% if options[:class_name] %}
        {% class_name = options[:class_name] %}
      {% else %}
        {% plural_name = name.id.stringify %}
        {% if plural_name.ends_with?("ies") %}
          {% singular_name = plural_name[0...(plural_name.size - 3)] + "y" %}
        {% elsif plural_name.ends_with?("ses") || plural_name.ends_with?("xes") || plural_name.ends_with?("zes") || plural_name.ends_with?("ches") || plural_name.ends_with?("shes") %}
          {% singular_name = plural_name[0...(plural_name.size - 2)] %}
        {% elsif plural_name.ends_with?("s") && !plural_name.ends_with?("ss") %}
          {% singular_name = plural_name[0...(plural_name.size - 1)] %}
        {% else %}
          {% singular_name = plural_name %}
        {% end %}
        {% class_name = singular_name.camelcase %}
      {% end %}
    {% end %}

    @[Grant::Relationship(target: {{class_name.id}}, type: :has_many, polymorphic_as: {{poly_as.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}}, type_column: {{type_column.id.stringify}},
      primary_key: {{primary_key_name}}, scope: nil)]
    def {{method_name.id}}
      loaded_records = nil.as(Array({{class_name.id}})?)
      if association_loaded?({{method_name.stringify}})
        loaded_data = get_loaded_association({{method_name.stringify}})
        if loaded_data.is_a?(Array(Grant::Base))
          loaded_records = loaded_data.map(&.as({{class_name.id}}))
        end
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
      Grant::AssociationCollection(self, {{class_name.id}}).new(
        self, {{foreign_key.id.stringify}}, nil, {{options[:primary_key] ? primary_key_name : nil}},
        {{inverse_of ? inverse_of.id.stringify : nil}}, nil, {{method_name.stringify}}, loaded_records, nil, nil,
        strict_loading_option: {{options[:strict_loading]}},
        automatic_inverse: false,
        type_column: {{type_column.id.stringify}},
        type_value: self.class.polymorphic_name,
        dependent: {{options[:dependent].is_a?(SymbolLiteral) ? options[:dependent] : nil}},
        callbacks: callbacks
      )
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{method_name.stringify}})
    end

    def reload_{{method_name.id}}
      reload_association({{method_name.stringify}})
      {{method_name.id}}
    end

    # The rows this record owns through the polymorphic interface.
    protected def _{{method_name.id}}_relation : Grant::Query::Builder({{class_name.id}})
      {{class_name.id}}.where({{type_column.id.stringify}}, :eq, self.class.polymorphic_name)
        .where({{foreign_key.id.stringify}}, :eq, self.read_attribute({{primary_key_name}}))
    end

    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_many,
      polymorphic_as: {{poly_as.id.stringify}},
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}}
    }

    _grant_register_reflection({{method_name.id.stringify}}, :has_many, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key_name}},
      {{type_column.id.stringify}}, {{poly_as.id.stringify}}, nil, nil, {{options[:dependent]}}, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      false, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    # Register this owner model as a concrete polymorphic target.
    register_polymorphic_type

    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        before_destroy do
          _{{method_name.id}}_relation.select.each(&.destroy)
        end
      {% elsif options[:dependent] == :delete_all || options[:dependent] == :delete %}
        before_destroy do
          _{{method_name.id}}_relation.delete_all
        end
      {% elsif options[:dependent] == :nullify %}
        before_destroy do
          _{{method_name.id}}_relation.update_all({{foreign_key.id}}: nil, {{type_column.id}}: nil)
        end
      {% elsif options[:dependent] == :restrict %}
        before_destroy do
          if _{{method_name.id}}_relation.exists?
            errors << Grant::Error.new(:base, "Cannot delete record because dependent {{method_name.id}} exist")
            abort!
          end
        end
      {% elsif options[:dependent] == :restrict_with_exception %}
        before_destroy do
          if _{{method_name.id}}_relation.exists?
            raise Grant::Associations::RestrictError.new({{method_name.id.stringify}})
          end
        end
      {% end %}
    {% end %}
  end

  # Implements the polymorphic `has_one` (invoked by
  # `has_one :name, as: :poly_as`).
  #
  # Generates `#<name> : Target?`, `#<name>! : Target`, and `#<name>=` for the
  # single record whose `<poly_as>_type` equals this model's `polymorphic_name`
  # and whose `<poly_as>_id` equals this record's primary key. The result is
  # cached, preloadable with `includes`, and every `dependent:` option works.
  #
  # Options: `class_name:` sets the target class, `foreign_key:` / `type_column:`
  # override the derived `<poly_as>_id` / `<poly_as>_type` column names, and
  # `inverse_of:` names the polymorphic `belongs_to` on the target.
  #
  # ```
  # class Account < Grant::Base
  #   has_one :avatar, as: :imageable
  # end
  #
  # account.avatar         # => Image? where imageable_type="Account" AND imageable_id=account.id
  # account.avatar!        # => Image  (raises Grant::Querying::NotFound if absent)
  # account.avatar = image # sets image.imageable_id / imageable_type in memory
  # ```
  macro has_one_polymorphic(name, poly_as, **options)
    {% foreign_key = options[:foreign_key] || (poly_as.id.stringify + "_id") %}
    {% type_column = options[:type_column] || (poly_as.id.stringify + "_type") %}
    {% primary_key = options[:primary_key] || "id" %}
    {% primary_key_name = primary_key.stringify.gsub(/:/, "").gsub(/"/, "") %}
    {% inverse_of = options[:inverse_of] %}
    {% if name.is_a? TypeDeclaration %}
      {% method_name = name.var %}
      {% class_name = name.type %}
    {% else %}
      {% method_name = name.id %}
      {% class_name = options[:class_name] || name.id.camelcase %}
    {% end %}

    @[Grant::Relationship(target: {{class_name.id}}, type: :has_one, polymorphic_as: {{poly_as.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}}, type_column: {{type_column.id.stringify}},
      primary_key: {{primary_key_name}}, scope: nil)]
    def {{method_name.id}} : {{class_name.id}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      else
        assert_association_can_lazy_load!({{method_name.stringify}}, {{options[:strict_loading]}})
        result = _{{method_name.id}}_relation.first
        set_loaded_association({{method_name.stringify}}, result)
        _adopt_strict_loading(result, false)
        {% if inverse_of %}
          result.set_loaded_association({{inverse_of.id.stringify}}, self) if result
        {% end %}
        result
      end
    end

    def {{method_name.id}}! : {{class_name.id}}
      {{method_name.id}} || raise Grant::Querying::NotFound.new("No {{class_name.id}} found for #{self.class.name} with id #{primary_key_value}")
    end

    # Points *child* at this record (in memory; save the child to persist).
    def {{method_name.id}}=(child : {{class_name.id}}?)
      if child
        child.set_attributes({ {{foreign_key.id.stringify}} => self.read_attribute({{primary_key_name}}), {{type_column.id.stringify}} => self.class.polymorphic_name })
      end
      set_loaded_association({{method_name.stringify}}, child)
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{method_name.stringify}})
    end

    def reload_{{method_name.id}} : {{class_name.id}}?
      reload_association({{method_name.stringify}})
      {{method_name.id}}
    end

    # The rows this record owns through the polymorphic interface.
    protected def _{{method_name.id}}_relation : Grant::Query::Builder({{class_name.id}})
      {{class_name.id}}.where({{type_column.id.stringify}}, :eq, self.class.polymorphic_name)
        .where({{foreign_key.id.stringify}}, :eq, self.read_attribute({{primary_key_name}}))
    end

    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_one,
      polymorphic_as: {{poly_as.id.stringify}},
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}}
    }

    _grant_register_reflection({{method_name.id.stringify}}, :has_one, {{class_name.id}}, {{foreign_key.id.stringify}}, {{primary_key_name}},
      {{type_column.id.stringify}}, {{poly_as.id.stringify}}, nil, nil, {{options[:dependent]}}, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      false, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    # Register this owner model as a concrete polymorphic target.
    register_polymorphic_type

    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        before_destroy do
          _{{method_name.id}}_relation.first.try(&.destroy)
        end
      {% elsif options[:dependent] == :delete_all || options[:dependent] == :delete %}
        before_destroy do
          _{{method_name.id}}_relation.delete_all
        end
      {% elsif options[:dependent] == :nullify %}
        before_destroy do
          _{{method_name.id}}_relation.update_all({{foreign_key.id}}: nil, {{type_column.id}}: nil)
        end
      {% elsif options[:dependent] == :restrict %}
        before_destroy do
          if _{{method_name.id}}_relation.exists?
            errors << Grant::Error.new(:base, "Cannot delete record because dependent {{method_name.id}} exists")
            abort!
          end
        end
      {% elsif options[:dependent] == :restrict_with_exception %}
        before_destroy do
          if _{{method_name.id}}_relation.exists?
            raise Grant::Associations::RestrictError.new({{method_name.id.stringify}})
          end
        end
      {% end %}
    {% end %}
  end

  # Registers the current model as a resolvable polymorphic target, keyed by its
  # own class name. Call this in any model that can be the target of a
  # polymorphic `belongs_to`; the `as:` side of `has_many`/`has_one` triggers it
  # for you. Required so `load_polymorphic` can turn a stored `*_type` string
  # back into a record.
  #
  # ```
  # class Post < Grant::Base
  #   register_polymorphic_type # now "Post" resolves via load_polymorphic
  # end
  # ```
  macro register_polymorphic_type
    Grant::Polymorphic.register_polymorphic_type({{@type.name.stringify}}, {{@type}})
  end
end
