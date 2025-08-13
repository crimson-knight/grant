module Grant
  # Registry to store association metadata for each model class
  class AssociationRegistry
    alias AssociationMeta = NamedTuple(
      type: Symbol,
      target_class: Grant::Base.class,
      foreign_key: String,
      primary_key: String,
      through: String?
    )
    
    @@registry = {} of String => Hash(String, AssociationMeta)
    
    def self.register(model_class : String, association_name : String, metadata : AssociationMeta)
      @@registry[model_class] ||= {} of String => AssociationMeta
      @@registry[model_class][association_name] = metadata
    end
    
    def self.get(model_class : String, association_name : String) : AssociationMeta?
      if class_registry = @@registry[model_class]?
        class_registry[association_name]?
      end
    end
    
    def self.get_for_model(model : Grant::Base, association_name : String) : AssociationMeta?
      get(model.class.name, association_name)
    end
  end
end