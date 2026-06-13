require "./association_registry"
require "./polymorphic"
require "./association_options"

module Grant::Associations
  include Grant::Polymorphic
  include Grant::AssociationOptions::DependentCallbacks
  include Grant::AssociationOptions::CounterCache
  include Grant::AssociationOptions::TouchCallbacks
  include Grant::AssociationOptions::AutosaveCallbacks
  include Grant::AssociationOptions::OptionalValidation

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

  macro has_many(model, scope = nil, **options)
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

  # Helper method to get association metadata
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
