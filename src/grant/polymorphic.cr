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
    def self.load_polymorphic(type_name : String, id : Int64) : Grant::Base?
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          nil
        {% else %}
          {{klass}}.find(id)
        {% end %}
      {% end %}
      else
        nil
      end
    end
    
    # Like `load_polymorphic`, but raises `Grant::Querying::NotFound` instead of
    # returning `nil`.
    #
    # ```
    # Grant::Polymorphic.load_polymorphic!("Post", 1_i64) # => Post (raises if absent)
    # ```
    def self.load_polymorphic!(type_name : String, id : Int64) : Grant::Base
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
        {% if name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
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
    getter id : Int64?

    def initialize(@type : String?, @id : Int64?)
    end

    # Resolves and returns the target record, or `nil` when the type/id are
    # unset or no matching row exists.
    #
    # ```
    # comment.commentable_proxy.load # => Post? / Photo? / nil
    # ```
    def load : Grant::Base?
      return nil unless @type && @id
      Grant::Polymorphic.load_polymorphic(@type.not_nil!, @id.not_nil!)
    end

    # Resolves and returns the target record, raising `Grant::Querying::NotFound`
    # when the association is unset or the row is missing.
    #
    # ```
    # comment.commentable_proxy.load! # => Grant::Base (raises if absent)
    # ```
    def load! : Grant::Base
      raise Grant::Querying::NotFound.new("Polymorphic association not set") unless @type && @id
      Grant::Polymorphic.load_polymorphic!(@type.not_nil!, @id.not_nil!)
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
    {% primary_key = options[:primary_key] || "id" %}
    
    # Define the foreign key column
    column {{foreign_key.id}} : Int64?
    
    # Define the type column
    column {{type_column.id}} : String?
    
    # Define proxy getter
    def {{name.id}}_proxy : Grant::Polymorphic::PolymorphicProxy
      Grant::Polymorphic::PolymorphicProxy.new(@{{type_column.id}}, @{{foreign_key.id}})
    end
    
    # Define getter method
    def {{name.id}} : Grant::Base?
      {{name.id}}_proxy.load
    end
    
    # Define bang getter
    def {{name.id}}! : Grant::Base
      {{name.id}}_proxy.load!
    end
    
    # Define setter method
    def {{name.id}}=(record : Grant::Base?)
      if record.nil?
        @{{foreign_key.id}} = nil
        @{{type_column.id}} = nil
      else
        # Get primary key value and ensure it's Int64
        pk_value = record.primary_key_value
        @{{foreign_key.id}} = case pk_value
                              when Int64
                                pk_value
                              when Int32
                                pk_value.to_i64
                              else
                                raise "Polymorphic associations require numeric primary keys, got #{pk_value.class}"
                              end
        @{{type_column.id}} = record.class.name
      end
    end
    
    # Store association metadata
    class_getter _{{name.id}}_association_meta = {
      type: :belongs_to,
      polymorphic: true,
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}},
      primary_key: {{primary_key.id.stringify}}
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
  # Generates `#<name>` returning a collection of records whose `<poly_as>_type`
  # equals this model's class name and whose `<poly_as>_id` equals this record's
  # primary key. Supports `dependent: :destroy` and `dependent: :nullify`.
  #
  # Options: `class_name:` sets the target class, `foreign_key:` / `type_column:`
  # override the derived `<poly_as>_id` / `<poly_as>_type` column names.
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
    {% if name.is_a? TypeDeclaration %}
      {% method_name = name.var %}
      {% class_name = name.type %}
    {% else %}
      {% method_name = name.id %}
      {% class_name = options[:class_name] || name.id.stringify.camelcase %}
    {% end %}
    
    def {{method_name.id}}
      if association_loaded?({{method_name.stringify}})
        loaded_data = get_loaded_association({{method_name.stringify}})
        if loaded_data.is_a?(Array(Grant::Base))
          Grant::LoadedAssociationCollection(self, {{class_name.id}}).new(loaded_data.map(&.as({{class_name.id}})))
        else
          # For polymorphic, we need to use where query with both type and id
          records = {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value).select
          Grant::LoadedAssociationCollection(self, {{class_name.id}}).new(records)
        end
      else
        # For polymorphic, we need to use where query with both type and id
        records = {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value).select
        Grant::LoadedAssociationCollection(self, {{class_name.id}}).new(records)
      end
    end
    
    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_many,
      polymorphic_as: {{poly_as.id.stringify}},
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}}
    }
    
    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        before_destroy do
          {{method_name.id}}.each(&.destroy)
        end
      {% elsif options[:dependent] == :nullify %}
        before_destroy do
          {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
            .update_all({{foreign_key.id}}: nil, {{type_column.id}}: nil)
        end
      {% end %}
    {% end %}
  end

  # Implements the polymorphic `has_one` (invoked by
  # `has_one :name, as: :poly_as`).
  #
  # Generates `#<name> : Target?` and `#<name>! : Target` returning the single
  # record whose `<poly_as>_type` equals this model's class name and whose
  # `<poly_as>_id` equals this record's primary key. Supports
  # `dependent: :destroy` and `dependent: :nullify`.
  #
  # Options: `class_name:` sets the target class, `foreign_key:` / `type_column:`
  # override the derived `<poly_as>_id` / `<poly_as>_type` column names.
  #
  # ```
  # class Account < Grant::Base
  #   has_one :avatar, as: :imageable
  # end
  #
  # account.avatar  # => Image? where imageable_type="Account" AND imageable_id=account.id
  # account.avatar! # => Image  (raises Grant::Querying::NotFound if absent)
  # ```
  macro has_one_polymorphic(name, poly_as, **options)
    {% foreign_key = options[:foreign_key] || (poly_as.id.stringify + "_id") %}
    {% type_column = options[:type_column] || (poly_as.id.stringify + "_type") %}
    {% if name.is_a? TypeDeclaration %}
      {% method_name = name.var %}
      {% class_name = name.type %}
    {% else %}
      {% method_name = name.id %}
      {% class_name = options[:class_name] || name.id.camelcase %}
    {% end %}
    
    def {{method_name.id}} : {{class_name.id}}?
      {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value).first
    end
    
    def {{method_name.id}}! : {{class_name.id}}
      {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value).first || raise Grant::Querying::NotFound.new("No {{class_name.id}} found for #{self.class.name} with id #{primary_key_value}")
    end
    
    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_one,
      polymorphic_as: {{poly_as.id.stringify}},
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      type_column: {{type_column.id.stringify}}
    }
    
    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        before_destroy do
          {{method_name.id}}.try(&.destroy)
        end
      {% elsif options[:dependent] == :nullify %}
        before_destroy do
          {{class_name.id}}.where({{type_column.id}}: self.class.name, {{foreign_key.id}}: primary_key_value)
            .update_all({{foreign_key.id}}: nil, {{type_column.id}}: nil)
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
