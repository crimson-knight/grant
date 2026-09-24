module Grant
  # Registry to store association metadata for each model class. Public
  # registration and lookup methods are synchronized because model classes can
  # load while application fibers are querying associations.
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

    @@registry = {} of String => Hash(String, AssociationMeta)
    @@writers = {} of String => Hash(String, AssociationWriter)
    @@mutex = Mutex.new

    def self.register(model_class : String, association_name : String, metadata : AssociationMeta) : Nil
      @@mutex.synchronize do
        @@registry[model_class] ||= {} of String => AssociationMeta
        @@registry[model_class][association_name] = metadata
      end
    end

    def self.get(model_class : String, association_name : String) : AssociationMeta?
      @@mutex.synchronize do
        if class_registry = @@registry[model_class]?
          class_registry[association_name]?
        end
      end
    end

    def self.get_for_model(model : Grant::Base, association_name : String) : AssociationMeta?
      get(model.class.name, association_name)
    end

    def self.register_writer(model_class : String, association_name : String, writer : AssociationWriter) : Nil
      @@mutex.synchronize do
        @@writers[model_class] ||= {} of String => AssociationWriter
        @@writers[model_class][association_name] = writer
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
      writer = @@mutex.synchronize do
        @@writers[owner.class.name]?.try(&.[association_name]?)
      end
      writer ? writer.call(owner, value) : false
    end
  end
end
