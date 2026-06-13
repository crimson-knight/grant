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
      loaded_associations[name.to_s] = data
    end

    # Clear all loaded associations
    def clear_loaded_associations
      loaded_associations.clear
    end

    # Batch-loads a named association for an array of records of this model.
    # Issues exactly one SQL query per direct association type (belongs_to,
    # has_one, has_many) and distributes results to every record in the array
    # so subsequent accessor calls return cached data without extra queries.
    #
    # has_many :through associations are not batch-loaded here — they fall back
    # to lazy loading transparently.  Polymorphic associations also fall back.
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
              fk = \{{ann[:foreign_key].id.stringify}}
              pk = \{{ann[:primary_key].id.stringify}}
              fk_values = records.compact_map { |r|
                v = r.read_attribute(fk)
                v.is_a?(DB::Any) ? v.as(DB::Any) : nil
              }.uniq
              unless fk_values.empty?
                placeholders = fk_values.map { "?" }.join(", ")
                loaded = \{{ann[:target].id}}.raw_all("WHERE #{pk} IN (#{placeholders})", fk_values)
                lookup = {} of Grant::Columns::Type => Grant::Base
                loaded.each { |r| lookup[r.read_attribute(pk)] = r.as(Grant::Base) }
                records.each do |record|
                  fkv = record.read_attribute(fk)
                  record.set_loaded_association(assoc_name, lookup[fkv]?.as(Grant::Base | Nil))
                end
              else
                records.each { |record| record.set_loaded_association(assoc_name, nil) }
              end
              return true
            end
          \{% elsif assoc_type == :has_one %}
            if assoc_name == \{{method.name.symbolize}}
              pk = \{{ann[:primary_key].id.stringify}}
              fk = \{{ann[:foreign_key].id.stringify}}
              pk_values = records.compact_map { |r|
                v = r.read_attribute(pk)
                v.is_a?(DB::Any) ? v.as(DB::Any) : nil
              }.uniq
              unless pk_values.empty?
                placeholders = pk_values.map { "?" }.join(", ")
                loaded = \{{ann[:target].id}}.raw_all("WHERE #{fk} IN (#{placeholders})", pk_values)
                grouped = {} of Grant::Columns::Type => Grant::Base
                loaded.each { |r| grouped[r.read_attribute(fk)] = r.as(Grant::Base) }
                records.each do |record|
                  pkv = record.read_attribute(pk)
                  record.set_loaded_association(assoc_name, grouped[pkv]?.as(Grant::Base | Nil))
                end
              else
                records.each { |record| record.set_loaded_association(assoc_name, nil) }
              end
              return true
            end
          \{% elsif assoc_type == :has_many %}
            \{% if ann[:through] %}
            \{% else %}
              \{% own_pk = @type.instance_vars.find { |v| (a = v.annotation(Grant::Column)) && a[:primary] } %}
              \{% pk_name = own_pk ? own_pk.name.stringify : "id" %}
              if assoc_name == \{{method.name.symbolize}}
                pk = \{{pk_name}}
                fk = \{{ann[:foreign_key].id.stringify}}
                pk_values = records.compact_map { |r|
                  v = r.read_attribute(pk)
                  v.is_a?(DB::Any) ? v.as(DB::Any) : nil
                }.uniq
                unless pk_values.empty?
                  placeholders = pk_values.map { "?" }.join(", ")
                  loaded = \{{ann[:target].id}}.raw_all("WHERE #{fk} IN (#{placeholders})", pk_values)
                  grouped = {} of Grant::Columns::Type => Array(Grant::Base)
                  loaded.each do |r|
                    fkv = r.read_attribute(fk)
                    grouped[fkv] ||= [] of Grant::Base
                    grouped[fkv] << r.as(Grant::Base)
                  end
                  records.each do |record|
                    pkv = record.read_attribute(pk)
                    record.set_loaded_association(assoc_name, (grouped[pkv]? || [] of Grant::Base).as(Array(Grant::Base)))
                  end
                else
                  records.each { |record| record.set_loaded_association(assoc_name, [] of Grant::Base) }
                end
                return true
              end
            \{% end %}
          \{% end %}
        \{% end %}
      \{% end %}
      false
    end
  end

  module ClassMethods
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
        db_type = case adapter.class.to_s
                  when /Pg/
                    Grant::Query::Builder::DbType::Pg
                  when /Mysql/
                    Grant::Query::Builder::DbType::Mysql
                  else
                    Grant::Query::Builder::DbType::Sqlite
                  end
        Grant::Query::Builder(self).new(db_type)
      end
    end
  end
end
