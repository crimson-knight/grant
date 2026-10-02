class Grant::StrictLoadingViolationError < Grant::ErrorBase
end

module Grant::EagerLoading
  macro included
    # Eager-loaded association cache.
    # Declared nilable (with lazy initialization in `loaded_associations` below)
    # rather than carrying a default value so that `YAML::Serializable` /
    # `JSON::Serializable`'s auto-generated deserialization initializer — included
    # on the abstract `Grant::Base` — does not report it as uninitialized for
    # `Grant::Base+`. See issues #39/#41.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @loaded_associations : Hash(String, Array(Grant::Base) | Grant::Base | Nil)?

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @strict_loading : Bool?

    protected def loaded_associations : Hash(String, Array(Grant::Base) | Grant::Base | Nil)
      @loaded_associations ||= {} of String => Array(Grant::Base) | Grant::Base | Nil
    end

    # Check if an association has been loaded
    def association_loaded?(name : String | Symbol)
      loaded_associations.has_key?(name.to_s)
    end

    # Get loaded association data
    def get_loaded_association(name : String | Symbol)
      loaded_associations[name.to_s]?
    end

    # Set loaded association data
    def set_loaded_association(name : String | Symbol, data)
      if data.is_a?(Array)
        records = [] of Grant::Base
        data.each do |record|
          raise ArgumentError.new("Loaded association arrays must contain Grant models") unless record.is_a?(Grant::Base)
          records << record.as(Grant::Base)
        end
        loaded_associations[name.to_s] = records
      else
        loaded_associations[name.to_s] = data.as(Grant::Base | Nil)
      end
    end

    # Marks this record so accessing an association that has not already been
    # loaded raises `StrictLoadingViolationError`.
    def strict_loading!(value : Bool = true) : self
      @strict_loading = value
      self
    end

    def strict_loading? : Bool
      !!@strict_loading
    end

    def strict_loading : Bool
      strict_loading?
    end

    # Mirrors ActiveRecord's writable strict-loading flag.
    def strict_loading=(value : Bool)
      @strict_loading = value
    end

    # Called by generated association accessors and collection proxies before
    # they issue a lazy query.
    def assert_association_can_lazy_load!(name : String) : Nil
      if strict_loading?
        raise Grant::StrictLoadingViolationError.new("#{self.class.name}##{name} was not preloaded and strict loading is enabled")
      end
    end

    # Clear all loaded associations
    def clear_loaded_associations
      loaded_associations.clear
    end

    # Batch-loads a named association for records of this model and distributes
    # results so subsequent accessor calls return cached data. Direct
    # associations use one query; polymorphic belongs_to loads once per target
    # type; through collections load bridge rows and then target rows.
    #
    # has_many :through associations load bridge rows and then target rows.
    # Polymorphic belongs_to associations are grouped by stored target type so
    # each concrete target receives one scoped batch query.
    #
    # The method body iterates @type.methods at compile time per concrete class,
    # giving full type knowledge for each association target.
    #
    # KNOWN LIMITATION: @type.methods only yields methods defined directly on
    # the concrete class.  Associations declared on an intermediate abstract
    # base class are not seen here and silently fall back to lazy loading.
    # If shared-base-class associations become a pattern, iterate the
    # ancestors' methods as well.
    #
    # Returns true when the association was recognised, false otherwise.
    def _eager_batch_load(records : Array(Grant::Base), assoc_name : Symbol) : Bool
      \{% for method in @type.methods %}
        \{% ann = method.annotation(Grant::Relationship) %}
        \{% if ann && ann[:target].resolve? %}
          \{% assoc_type = ann[:type] %}
          \{% if assoc_type == :belongs_to %}
            if assoc_name == \{{method.name.symbolize}}
              \{% if ann[:polymorphic] %}
                foreign_key = \{{ann[:foreign_key].id.stringify}}
                type_column = \{{ann[:type_column].id.stringify}}
                primary_key = \{{ann[:primary_key].id.stringify}}
                ids_by_type = {} of String => Array(Grant::Columns::Type)
                records.each do |record|
                  type_name = record.read_attribute(type_column)
                  target_id = record.read_attribute(foreign_key)
                  if type_name.is_a?(String) && !target_id.nil?
                    ids_by_type[type_name] ||= [] of Grant::Columns::Type
                    ids_by_type[type_name] << target_id
                  end
                end
                lookup = {} of Tuple(String, Grant::Columns::Type) => Grant::Base
                ids_by_type.each do |type_name, ids|
                  Grant::Polymorphic.load_polymorphic_batch(type_name, primary_key, ids.uniq).each do |target|
                    lookup[{type_name, target.read_attribute(primary_key)}] = target
                  end
                end
                records.each do |record|
                  type_name = record.read_attribute(type_column)
                  target_id = record.read_attribute(foreign_key)
                  value = if type_name.is_a?(String) && !target_id.nil?
                            lookup[{type_name, target_id}]?.as(Grant::Base | Nil)
                          else
                            nil
                          end
                  record.set_loaded_association(assoc_name, value)
                end
              \{% else %}
                foreign_key = \{{ann[:foreign_key].id.stringify}}
                primary_key = \{{ann[:primary_key].id.stringify}}
                key_values = [] of Grant::Columns::Type
                records.each do |record|
                  value = record.read_attribute(foreign_key)
                  key_values << value unless value.nil?
                end
                key_values.uniq!
                lookup = {} of Grant::Columns::Type => Grant::Base
                unless key_values.empty?
                  placeholders = key_values.map { "?" }.join(", ")
                  target_model = \{{ann[:target].id}}
                  quoted_primary_key = target_model.quote(primary_key)
                  loaded = target_model.all("WHERE #{quoted_primary_key} IN (#{placeholders})", key_values).to_a
                  loaded.each { |target| lookup[target.read_attribute(primary_key)] = target.as(Grant::Base) }
                end
                records.each do |record|
                  key = record.read_attribute(foreign_key)
                  record.set_loaded_association(assoc_name, lookup[key]?.as(Grant::Base | Nil))
                end
              \{% end %}
              return true
            end
          \{% elsif assoc_type == :has_one %}
            if assoc_name == \{{method.name.symbolize}}
              primary_key = \{{ann[:primary_key].id.stringify}}
              foreign_key = \{{ann[:foreign_key].id.stringify}}
              owner_values = [] of Grant::Columns::Type
              records.each do |record|
                value = record.read_attribute(primary_key)
                owner_values << value unless value.nil?
              end
              owner_values.uniq!
              lookup = {} of Grant::Columns::Type => Grant::Base
              unless owner_values.empty?
                placeholders = owner_values.map { "?" }.join(", ")
                target_model = \{{ann[:target].id}}
                quoted_foreign_key = target_model.quote(foreign_key)
                loaded = target_model.all("WHERE #{quoted_foreign_key} IN (#{placeholders})", owner_values).to_a
                loaded.each { |target| lookup[target.read_attribute(foreign_key)] = target.as(Grant::Base) }
              end
              records.each do |record|
                key = record.read_attribute(primary_key)
                record.set_loaded_association(assoc_name, lookup[key]?.as(Grant::Base | Nil))
              end
              return true
            end
          \{% elsif assoc_type == :has_many %}
            if assoc_name == \{{method.name.symbolize}}
              \{% if ann[:through] %}
                \{% through_name = ann[:through].id.stringify %}
                \{% through_method = @type.methods.find { |candidate| candidate.name.stringify == through_name } %}
                \{% through_ann = through_method ? through_method.annotation(Grant::Relationship) : nil %}
                \{% join_model = through_ann && through_ann[:target].resolve? ? through_ann[:target] : nil %}
                \{% source_name = ann[:source].id.stringify %}
                \{% source_method = join_model && join_model.resolve.methods.find { |candidate| candidate.name.stringify == source_name } %}
                \{% source_ann = source_method ? source_method.annotation(Grant::Relationship) : nil %}
                \{% unless join_model && source_ann && source_ann[:target].resolve? %}
                  \{% raise "Cannot preload through association; declare a resolvable through and source association" %}
                \{% end %}
                owner_primary_key = \{{ann[:owner_primary_key].id.stringify}}
                join_owner_key = \{{through_ann[:foreign_key].id.stringify}}
                source_foreign_key = \{{source_ann[:foreign_key].id.stringify}}
                target_primary_key = \{{source_ann[:primary_key].id.stringify}}
                owner_values = [] of Grant::Columns::Type
                records.each do |record|
                  value = record.read_attribute(owner_primary_key)
                  owner_values << value unless value.nil?
                end
                owner_values.uniq!
                join_rows = [] of \{{join_model.id}}
                unless owner_values.empty?
                  placeholders = owner_values.map { "?" }.join(", ")
                  join_model_class = \{{join_model.id}}
                  quoted_join_key = join_model_class.quote(join_owner_key)
                  join_rows = join_model_class.all("WHERE #{quoted_join_key} IN (#{placeholders})", owner_values).to_a
                end
                target_values = [] of Grant::Columns::Type
                join_rows.each do |join_row|
                  value = join_row.read_attribute(source_foreign_key)
                  target_values << value unless value.nil?
                end
                target_values.uniq!
                targets = [] of \{{source_ann[:target].id}}
                unless target_values.empty?
                  placeholders = target_values.map { "?" }.join(", ")
                  target_model = \{{source_ann[:target].id}}
                  quoted_target_key = target_model.quote(target_primary_key)
                  targets = target_model.all("WHERE #{quoted_target_key} IN (#{placeholders})", target_values).to_a
                end
                target_lookup = {} of Grant::Columns::Type => Grant::Base
                targets.each { |target| target_lookup[target.read_attribute(target_primary_key)] = target.as(Grant::Base) }
                records.each do |record|
                  owner_value = record.read_attribute(owner_primary_key)
                  associated = [] of Grant::Base
                  join_rows.each do |join_row|
                    next unless join_row.read_attribute(join_owner_key) == owner_value
                    target_value = join_row.read_attribute(source_foreign_key)
                    if target = target_lookup[target_value]?
                      associated << target
                    end
                  end
                  record.set_loaded_association(assoc_name, associated)
                end
              \{% else %}
                primary_key = \{{ann[:primary_key].id.stringify}}
                foreign_key = \{{ann[:foreign_key].id.stringify}}
                owner_values = [] of Grant::Columns::Type
                records.each do |record|
                  value = record.read_attribute(primary_key)
                  owner_values << value unless value.nil?
                end
                owner_values.uniq!
                loaded = [] of \{{ann[:target].id}}
                unless owner_values.empty?
                  placeholders = owner_values.map { "?" }.join(", ")
                  target_model = \{{ann[:target].id}}
                  quoted_foreign_key = target_model.quote(foreign_key)
                  loaded = target_model.all("WHERE #{quoted_foreign_key} IN (#{placeholders})", owner_values).to_a
                end
                grouped = {} of Grant::Columns::Type => Array(Grant::Base)
                loaded.each do |target|
                  owner_value = target.read_attribute(foreign_key)
                  grouped[owner_value] ||= [] of Grant::Base
                  grouped[owner_value] << target.as(Grant::Base)
                end
                records.each do |record|
                  owner_value = record.read_attribute(primary_key)
                  record.set_loaded_association(assoc_name, grouped[owner_value]? || [] of Grant::Base)
                end
              \{% end %}
              return true
            end
          \{% end %}
        \{% end %}
      \{% end %}
      false
    end
  end

  module ClassMethods
    def strict_loading(value : Bool = true) : Grant::Query::Builder(self)
      query = get_query_builder
      query.strict_loading(value)
      query
    end

    def includes(*associations)
      query = get_query_builder
      query.includes(*associations)
      query
    end

    def includes(**nested_associations)
      query = get_query_builder
      nested_associations.each do |name, nested|
        query.includes({name => nested.is_a?(Array) ? nested : [nested]})
      end
      query
    end

    def preload(*associations)
      query = get_query_builder
      query.preload(*associations)
      query
    end

    def preload(**nested_associations)
      query = get_query_builder
      nested_associations.each do |name, nested|
        query.preload({name => nested.is_a?(Array) ? nested : [nested]})
      end
      query
    end

    def eager_load(*associations)
      query = get_query_builder
      query.eager_load(*associations)
      query
    end

    def eager_load(**nested_associations)
      query = get_query_builder
      nested_associations.each do |name, nested|
        query.eager_load({name => nested.is_a?(Array) ? nested : [nested]})
      end
      query
    end

    private def get_query_builder
      # Try to use current_scope if available (from Scoping module)
      if self.responds_to?(:current_scope)
        current_scope
      else
        # Fallback to creating a new query builder
        db_type = if adapter.postgres?
                    Grant::Query::Builder::DbType::Pg
                  elsif adapter.mysql?
                    Grant::Query::Builder::DbType::Mysql
                  else
                    Grant::Query::Builder::DbType::Sqlite
                  end
        Grant::Query::Builder(self).new(db_type)
      end
    end
  end
end
