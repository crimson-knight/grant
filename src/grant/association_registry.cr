module Grant
  # Registry of association metadata for each model class. Writes are
  # serialized and copy-on-write; reads take no lock.
  class AssociationRegistry
    alias AssociationValue = Grant::Base | Array(Grant::Base) | Nil
    alias AssociationWriter = Proc(Grant::Base, AssociationValue, Bool)
    alias AssociationMeta = NamedTuple(
      type: Symbol,
      target_class: Grant::Base.class,
      foreign_key: String,
      primary_key: String,
      through: String?,
      source: String?)

    # Registration happens while model classes load, before the application
    # serves requests. Every write publishes a fresh copy of the tables, so
    # readers never lock: they read one reference and see a complete snapshot.
    @@registry = {} of String => Hash(String, AssociationMeta)
    @@writers = {} of String => Hash(String, AssociationWriter)
    @@reflections = {} of String => Hash(String, Grant::Reflection)
    @@models = {} of String => Grant::Base.class
    @@inverses : Hash(Tuple(String, String), String)? = nil
    @@mutex = Mutex.new

    def self.register(model_class : String, association_name : String, metadata : AssociationMeta) : Nil
      @@mutex.synchronize do
        updated = @@registry.dup
        per_model = updated[model_class]?.try(&.dup) || {} of String => AssociationMeta
        per_model[association_name] = metadata
        updated[model_class] = per_model
        @@registry = updated
      end
    end

    def self.get(model_class : String, association_name : String) : AssociationMeta?
      @@registry[model_class]?.try(&.[association_name]?)
    end

    def self.get_for_model(model : Grant::Base, association_name : String) : AssociationMeta?
      get(model.class.name, association_name)
    end

    # Registers the full reflection of an association, in declaration order.
    def self.register_reflection(reflection : Grant::Reflection, owner : Grant::Base.class) : Nil
      @@mutex.synchronize do
        updated = @@reflections.dup
        per_model = updated[reflection.owner_name]?.try(&.dup) || {} of String => Grant::Reflection
        per_model[reflection.name] = reflection
        updated[reflection.owner_name] = per_model
        @@reflections = updated
        models = @@models.dup
        models[reflection.owner_name] = owner
        @@models = models
        @@inverses = nil
      end
    end

    def self.reflection(model_class : String, association_name : String) : Grant::Reflection?
      @@reflections[model_class]?.try(&.[association_name]?)
    end

    def self.reflections_for(model_class : String) : Array(Grant::Reflection)
      if per_model = @@reflections[model_class]?
        per_model.values
      else
        [] of Grant::Reflection
      end
    end

    def self.model_class(model_name : String) : (Grant::Base.class)?
      @@models[model_name]?
    end

    # Name of the association on the target model that is the inverse of
    # *reflection*, when the two line up without an explicit `inverse_of:`.
    # The index is built once after boot and rebuilt only if a model registers
    # later.
    def self.detected_inverse_name(reflection : Grant::Reflection) : String?
      index = @@inverses || build_inverse_index
      index[{reflection.owner_name, reflection.name}]?
    end

    # Built under the write lock so a registration that lands meanwhile cannot
    # be overwritten by an index computed from the older tables.
    private def self.build_inverse_index : Hash(Tuple(String, String), String)
      @@mutex.synchronize do
        @@inverses || compute_inverse_index
      end
    end

    private def self.compute_inverse_index : Hash(Tuple(String, String), String)
      index = {} of Tuple(String, String) => String
      @@reflections.each_value do |per_model|
        per_model.each_value do |reflection|
          next unless reflection.automatic_inverse_candidate?
          next unless candidates = @@reflections[reflection.class_name]?
          found = candidates.each_value.find do |candidate|
            candidate.automatic_inverse_candidate? && inverse_pair?(reflection, candidate)
          end
          index[{reflection.owner_name, reflection.name}] = found.name if found
        end
      end
      @@inverses = index
      index
    end

    # A has_one/has_many and a belongs_to are inverses when each names the
    # other's model and they share both keys. A belongs_to only pairs with a
    # has_one (a has_many owns many rows, so it cannot be one row's inverse).
    private def self.inverse_pair?(reflection : Grant::Reflection, candidate : Grant::Reflection) : Bool
      return false unless candidate.class_name == reflection.owner_name
      return false unless candidate.foreign_key == reflection.foreign_key
      return false unless candidate.primary_key == reflection.primary_key
      case reflection.macro
      when :belongs_to
        candidate.macro == :has_one
      else
        candidate.macro == :belongs_to
      end
    end

    def self.register_writer(model_class : String, association_name : String, writer : AssociationWriter) : Nil
      @@mutex.synchronize do
        updated = @@writers.dup
        per_model = updated[model_class]?.try(&.dup) || {} of String => AssociationWriter
        per_model[association_name] = writer
        updated[model_class] = per_model
        @@writers = updated
      end
    end

    # Apply association-valued mass-assignment entries through each
    # association's typed writer. Scalar column values are ignored here and
    # continue through the normal column conversion path.
    def self.assign(owner : Grant::Base, association_name : String, value) : Bool
      if value.nil?
        dispatch(owner, association_name, nil)
      elsif associated = value.as?(Grant::Base)
        dispatch(owner, association_name, associated)
      elsif value.is_a?(Array)
        associated = [] of Grant::Base
        value.each do |record|
          return false unless record.is_a?(Grant::Base)
          associated << record
        end
        dispatch(owner, association_name, associated)
      else
        false
      end
    end

    private def self.dispatch(owner : Grant::Base, association_name : String, value : AssociationValue) : Bool
      writer = @@writers[owner.class.name]?.try(&.[association_name]?)
      writer ? writer.call(owner, value) : false
    end
  end
end
