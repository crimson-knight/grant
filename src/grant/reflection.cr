module Grant
  # Raised when an association name (in `includes`, `preload`, `eager_load`,
  # `Grant::Preloader`, or `Model#association`) does not name an association
  # declared on the model.
  class AssociationNotFoundError < Grant::ErrorBase
    getter model_name : String
    getter association_name : String

    def initialize(@model_name : String, @association_name : String)
      super("Association named '#{@association_name}' was not found on #{@model_name}; perhaps you misspelled it?")
    end
  end

  # A nested association specification accepted by `includes`, `preload`, and
  # `eager_load`: a bare association name, or a name mapped to the associations
  # to load on the records it produces, to any depth.
  alias Includes = Symbol | Hash(Symbol, Array(Includes))

  # Immutable description of one association declared on a model, built by the
  # association macros at class-load time. It is the typed counterpart of
  # ActiveRecord's `AssociationReflection`.
  #
  # ```
  # if reflection = User.reflect_on_association(:posts)
  #   reflection.macro       # => :has_many
  #   reflection.klass       # => Post
  #   reflection.foreign_key # => "user_id"
  #   reflection.collection? # => true
  # end
  # ```
  struct Reflection
    getter owner_name : String
    getter name : String
    getter macro : Symbol
    getter class_name : String
    getter foreign_key : String
    getter primary_key : String
    # Type column of a polymorphic `belongs_to`, or of the `as:` side of a
    # polymorphic `has_many`/`has_one`.
    getter foreign_type : String?
    # The name of the polymorphic interface for `has_many/has_one ..., as:`.
    getter polymorphic_as : String?
    getter through : String?
    getter source : String?
    getter dependent : Symbol?
    # The explicit `inverse_of:` name, when given.
    getter inverse_of_name : String?
    getter strict_loading_option : Bool?
    getter options : Hash(String, String)

    def initialize(@owner_name : String, @name : String, @macro : Symbol,
                   @klass : Grant::Base.class, @class_name : String,
                   @foreign_key : String, @primary_key : String,
                   @foreign_type : String? = nil, @polymorphic_as : String? = nil,
                   @through : String? = nil, @source : String? = nil,
                   @dependent : Symbol? = nil, @inverse_of_name : String? = nil,
                   @inverse_disabled : Bool = false, @scoped : Bool = false,
                   @polymorphic : Bool = false, @strict_loading_option : Bool? = nil,
                   @options : Hash(String, String) = {} of String => String)
    end

    # The target model class. Raises `ArgumentError` for a polymorphic
    # `belongs_to`, which has no single target class.
    def klass : Grant::Base.class
      raise ArgumentError.new("Polymorphic association #{@owner_name}##{@name} has no single target class") if @polymorphic
      @klass
    end

    # The model that declares this association.
    def active_record : Grant::Base.class
      Grant::AssociationRegistry.model_class(@owner_name) || raise ArgumentError.new("Unknown model #{@owner_name}")
    end

    # True for a polymorphic `belongs_to` (`polymorphic: true`).
    def polymorphic? : Bool
      @polymorphic
    end

    # True for `has_many`.
    def collection? : Bool
      @macro == :has_many
    end

    def belongs_to? : Bool
      @macro == :belongs_to
    end

    def has_one? : Bool
      @macro == :has_one
    end

    def has_many? : Bool
      @macro == :has_many
    end

    def through? : Bool
      !@through.nil?
    end

    # True when the association was declared with a scope lambda.
    def scope? : Bool
      @scoped
    end

    def strict_loading? : Bool
      @strict_loading_option == true
    end

    def type : String?
      @foreign_type
    end

    # The reflection named by `through:`, on the owner model.
    def through_reflection : Reflection?
      if through_name = @through
        Grant::AssociationRegistry.reflection(@owner_name, through_name)
      end
    end

    # The reflection on the through model that produces the target records.
    def source_reflection : Reflection?
      return nil unless through_ref = through_reflection
      return nil if through_ref.polymorphic?
      source_name = @source || return nil
      Grant::AssociationRegistry.reflection(through_ref.klass.name, source_name)
    end

    # The reflection on the target model that points back at this association,
    # from an explicit `inverse_of:` or, when the keys line up and the
    # association has no scope, detected automatically. `nil` when there is no
    # inverse or it was disabled with `inverse_of: false`.
    def inverse_of : Reflection?
      if name = inverse_name
        Grant::AssociationRegistry.reflection(@class_name, name)
      end
    end

    # Name of the inverse association on the target model (explicit or
    # detected), or `nil`.
    def inverse_name : String?
      return nil if @inverse_disabled
      return @inverse_of_name if @inverse_of_name
      Grant::AssociationRegistry.detected_inverse_name(self)
    end

    # :nodoc:
    def automatic_inverse_candidate? : Bool
      !@inverse_disabled && !@scoped && !@polymorphic && @through.nil? && @polymorphic_as.nil? && @inverse_of_name.nil?
    end
  end
end

module Grant::Reflection::ClassMethods
  # Returns the reflection for the association named *name*, or `nil`.
  #
  # ```
  # User.reflect_on_association(:posts).try(&.macro) # => :has_many
  # ```
  def reflect_on_association(name : Symbol | String) : Grant::Reflection?
    Grant::AssociationRegistry.reflection(self.name, name.to_s)
  end

  # Returns the reflections of every association declared on this model, in
  # declaration order, optionally limited to one *macro*
  # (`:belongs_to`, `:has_one`, `:has_many`).
  def reflect_on_all_associations(macro_name : Symbol? = nil) : Array(Grant::Reflection)
    reflections = Grant::AssociationRegistry.reflections_for(self.name)
    return reflections unless macro_name
    reflections.select { |reflection| reflection.macro == macro_name }
  end
end

module Grant
  # A small view over one association of one record, for code that works on
  # associations by name (`record.association(:posts)`). It is built when asked
  # for; the readers the association macros generate never allocate it.
  #
  # ```
  # proxy = user.association(:posts)
  # proxy.loaded? # => false
  # proxy.target  # => Array(Grant::Base), loaded with one query
  # proxy.reset   # forget the cached value
  # ```
  struct AssociationProxy
    getter owner : Grant::Base
    getter reflection : Grant::Reflection

    def initialize(@owner : Grant::Base, @reflection : Grant::Reflection)
    end

    def name : String
      @reflection.name
    end

    # True when the association's value is cached on the owner.
    def loaded? : Bool
      @owner.association_loaded?(name)
    end

    # The associated record, records (for a collection), or `nil`, loading them
    # with one batch query the first time.
    def target : Grant::AssociationRegistry::AssociationValue
      @owner.reload_association(name) unless loaded?
      @owner.get_loaded_association(name)
    end

    # Forgets the cached value.
    def reset : Nil
      @owner.reset_association(name)
    end

    # Forgets the cached value and loads it again with one query.
    def reload : Grant::AssociationRegistry::AssociationValue
      @owner.reload_association(name)
      @owner.get_loaded_association(name)
    end
  end
end
