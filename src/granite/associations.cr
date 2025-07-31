require "./association_registry"
require "./polymorphic"
require "./association_options"

module Granite::Associations
  include Granite::Polymorphic
  include Granite::AssociationOptions::DependentCallbacks
  include Granite::AssociationOptions::CounterCache
  include Granite::AssociationOptions::TouchCallbacks
  include Granite::AssociationOptions::AutosaveCallbacks
  include Granite::AssociationOptions::OptionalValidation
  
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

    @[Granite::Relationship(target: {{class_name.id}}, type: :belongs_to,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}})]
    def {{method_name.id}} : {{class_name.id}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      elsif parent = {{class_name.id}}.find_by({{primary_key.id}}: {{foreign_key.id}})
        parent
      else
        {{class_name.id}}.new
      end
    end

    def {{method_name.id}}! : {{class_name.id}}
      {{class_name.id}}.find_by!({{primary_key.id}}: {{foreign_key.id}})
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

  macro has_one(model, **options)
    {% if options[:as] %}
      has_one_polymorphic({{model}}, {{options[:as]}}, {{options.double_splat}})
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

    @[Granite::Relationship(target: {{class_name.id}}, type: :has_one,
      primary_key: {{primary_key.id}}, foreign_key: {{foreign_key.id}})]

    def {{method_name}} : {{class_name}}?
      if association_loaded?({{method_name.stringify}})
        get_loaded_association({{method_name.stringify}}).as({{class_name.id}}?)
      else
        {{class_name.id}}.find_by({{foreign_key.id}}: self.{{primary_key.id}})
      end
    end

    def {{method_name}}! : {{class_name}}
      {{class_name.id}}.find_by!({{foreign_key.id}}: self.{{primary_key.id}})
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
    
    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        setup_dependent_destroy({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :nullify %}
        setup_dependent_nullify({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :restrict %}
        setup_dependent_restrict({{method_name.id}}, :has_one, {{class_name.id}}, {{foreign_key.id}})
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

  macro has_many(model, **options)
    {% if options[:as] %}
      has_many_polymorphic({{model}}, {{options[:as]}}, {{options.double_splat}})
    {% else %}
    {% if model.is_a? TypeDeclaration %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% class_name = options[:class_name] || model.id.camelcase %}
    {% end %}
    {% foreign_key = options[:foreign_key] || @type.stringify.split("::").last.underscore + "_id" %}
    {% primary_key = options[:primary_key] || class_name.stringify.split("::").last.underscore + "_id" %}
    {% through = options[:through] %}
    @[Granite::Relationship(target: {{class_name.id}}, through: {{through.id}}, type: :has_many,
      primary_key: {{through}}, foreign_key: {{foreign_key.id}})]
    def {{method_name.id}}
      if association_loaded?({{method_name.stringify}})
        loaded_data = get_loaded_association({{method_name.stringify}})
        if loaded_data.is_a?(Array(Granite::Base))
          # Return a wrapper that behaves like AssociationCollection but uses loaded data
          Granite::LoadedAssociationCollection(self, {{class_name.id}}).new(loaded_data.map(&.as({{class_name.id}})))
        else
          Granite::AssociationCollection(self, {{class_name.id}}).new(self, {{foreign_key}}, {{through}}, {{primary_key}})
        end
      else
        Granite::AssociationCollection(self, {{class_name.id}}).new(self, {{foreign_key}}, {{through}}, {{primary_key}})
      end
    end
    
    # Store association metadata
    class_getter _{{method_name.id}}_association_meta = {
      type: :has_many,
      target_class_name: {{class_name.id.stringify}},
      foreign_key: {{foreign_key.id.stringify}},
      primary_key: {{primary_key.id.stringify}},
      through: {{through ? through.id.stringify : nil}}
    }
    
    # Handle dependent option
    {% if options[:dependent] %}
      {% if options[:dependent] == :destroy %}
        setup_dependent_destroy({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :nullify %}
        setup_dependent_nullify({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
      {% elsif options[:dependent] == :restrict %}
        setup_dependent_restrict({{method_name.id}}, :has_many, {{class_name.id}}, {{foreign_key.id}})
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
  
  # Helper method to get association metadata
  macro association_metadata(name)
    self.class._{{name.id}}_association_meta
  end
end
