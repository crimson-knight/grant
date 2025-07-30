require "./association_registry"

module Granite::Associations
  macro belongs_to(model, **options)
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
  end

  macro has_one(model, **options)
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
  end

  macro has_many(model, **options)
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
  end
  
  # Helper method to get association metadata
  macro association_metadata(name)
    self.class._{{name.id}}_association_meta
  end
end
