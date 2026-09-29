class Grant::StrictLoadingViolationError < Grant::ErrorBase
end

# How a strict-loading record treats lazy association loads.
#
# * `All` raises (or logs) on every lazy load.
# * `NPlusOneOnly` allows a record to lazy-load its own associations, and only
#   marks the records it loads through `has_many` strict, so the N+1 pattern of
#   touching an association on each of many children is what gets flagged.
enum Grant::StrictLoadingMode
  All
  NPlusOneOnly
end

# What happens on a strict-loading violation.
enum Grant::StrictLoadingViolation
  Raise
  Log
end

class Grant::Settings
  # Action taken when a strict-loading record lazy-loads an association.
  property strict_loading_violation : Grant::StrictLoadingViolation = :raise
end

module Grant::EagerLoading
  # Per-model `strict_loading_by_default` flags, keyed by class name. Writes
  # are serialized and publish a fresh copy, so readers never lock and never
  # see a hash mid-update.
  @@strict_loading_defaults = {} of String => Bool
  @@strict_loading_defaults_mutex = Mutex.new

  # :nodoc:
  def self.strict_loading_default_for(model_name : String) : Bool
    defaults = @@strict_loading_defaults
    return false if defaults.empty?
    defaults.fetch(model_name) { defaults.fetch(Grant::Base.name, false) }
  end

  # :nodoc:
  def self.store_strict_loading_default(model_name : String, value : Bool) : Nil
    @@strict_loading_defaults_mutex.synchronize do
      updated = @@strict_loading_defaults.dup
      updated[model_name] = value
      @@strict_loading_defaults = updated
    end
  end

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

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @strict_loading_mode : Grant::StrictLoadingMode?

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

    # Marks this record so lazily loading an association that was not already
    # loaded raises `StrictLoadingViolationError` (or logs, per
    # `Grant.settings.strict_loading_violation`). Pass `mode: :n_plus_one_only`
    # to flag only the N+1 pattern (see `Grant::StrictLoadingMode`).
    def strict_loading!(value : Bool = true, mode : Grant::StrictLoadingMode = :all) : self
      @strict_loading = value
      @strict_loading_mode = mode
      self
    end

    # True when this record is strict loading, either set on the record or by
    # `Model.strict_loading_by_default`.
    def strict_loading? : Bool
      flag = @strict_loading
      flag.nil? ? self.class.strict_loading_by_default : flag
    end

    def strict_loading : Bool
      strict_loading?
    end

    # Mirrors ActiveRecord's writable strict-loading flag.
    def strict_loading=(value : Bool)
      @strict_loading = value
    end

    def strict_loading_mode : Grant::StrictLoadingMode
      @strict_loading_mode || Grant::StrictLoadingMode::All
    end

    def strict_loading_n_plus_one_only? : Bool
      strict_loading_mode.n_plus_one_only?
    end

    # Called by generated association accessors and collection proxies before
    # they issue a lazy query. *association_option* is the association's own
    # `strict_loading:` option, which wins over the record's flag when given.
    def assert_association_can_lazy_load!(name : String, association_option : Bool? = nil) : Nil
      violated = if association_option.nil?
                   strict_loading? && !strict_loading_n_plus_one_only?
                 else
                   association_option
                 end
      return unless violated

      message = "#{self.class.name}##{name} was not preloaded and strict loading is enabled"
      if Grant.settings.strict_loading_violation.log?
        Grant::Logs::Association.warn { message }
      else
        raise Grant::StrictLoadingViolationError.new(message)
      end
    end

    # Marks a record loaded through one of this record's associations as strict
    # when this record is. Under `:n_plus_one_only` only records loaded through
    # a collection association become strict.
    def _adopt_strict_loading(target : Grant::Base?, collection : Bool) : Nil
      return unless target
      return unless strict_loading?
      if strict_loading_n_plus_one_only?
        target.strict_loading! if collection
      else
        target.strict_loading!(true, strict_loading_mode)
      end
    end

    # Name of the association on the target model that is the inverse of the
    # association *name* (explicit `inverse_of:` or detected), if any.
    def _association_inverse(name : String) : String?
      Grant::AssociationRegistry.reflection(self.class.name, name).try(&.inverse_name)
    end

    # Forgets the loaded value of one association so the next read queries.
    def reset_association(name : String | Symbol) : Nil
      loaded_associations.delete(name.to_s)
    end

    # Forgets the loaded value of one association and loads it again with a
    # single batch query. Raises `Grant::AssociationNotFoundError` for an
    # unknown name.
    def reload_association(name : String | Symbol) : Nil
      reset_association(name)
      unless _eager_batch_load([self] of Grant::Base, name.to_s)
        raise Grant::AssociationNotFoundError.new(self.class.name, name.to_s)
      end
    end

    # Returns a small proxy over one association of this record, for generic
    # code that works on associations by name. Built on demand; the readers
    # generated by the association macros never allocate it.
    def association(name : String | Symbol) : Grant::AssociationProxy
      reflection = Grant::AssociationRegistry.reflection(self.class.name, name.to_s)
      raise Grant::AssociationNotFoundError.new(self.class.name, name.to_s) unless reflection
      Grant::AssociationProxy.new(self, reflection)
    end

    # True when the association *name* has been loaded (an alias of
    # `association_loaded?`, matching ActiveRecord's `association_cached?`).
    def association_cached?(name : String | Symbol) : Bool
      association_loaded?(name)
    end

    # Clear all loaded associations
    def clear_loaded_associations
      loaded_associations.clear
    end

    # Batch-loads the association *assoc_name* for *records* (all of this
    # model) and stores the results so later readers return cached data.
    #
    # Every case costs one IN query per association level: direct associations
    # one, polymorphic `belongs_to` one per stored target type, `through`
    # associations one for the join rows and one for the targets. Association
    # scopes and the target's default scope are applied in SQL, and IN lists
    # longer than `Grant.settings.in_clause_limit` are chunked.
    #
    # Associations declared on an abstract or STI parent class are found too.
    #
    # Returns true when the association was recognised, false otherwise.
    def _eager_batch_load(records : Array(Grant::Base), assoc_name : String,
                          restriction : Array(Grant::Query::WhereField)? = nil) : Bool
      \{% for owner_type in [@type] + @type.ancestors.select { |ancestor| ancestor.class? && ancestor < Grant::Base } %}
      \{% for method in owner_type.methods %}
        \{% ann = method.annotation(Grant::Relationship) %}
        \{% if ann && ann[:target].resolve? %}
          \{% scope = ann[:scope] %}
          \{% target = ann[:target].resolve %}
          if assoc_name == \{{method.name.stringify}}
            \{% if ann[:type] == :belongs_to %}
              \{% if ann[:polymorphic] %}
                Grant::AssociationLoader.preload_polymorphic_belongs_to(
                  records, assoc_name, \{{ann[:foreign_key].id.stringify}}, \{{ann[:type_column].id.stringify}},
                  \{{ann[:primary_key] ? ann[:primary_key].id.stringify : nil}})
              \{% else %}
                loader = ->(values : Array(Grant::Columns::Type)) : Array(Grant::Base) {
                  relation = \{{target}}.current_scope
                  \{% if scope.is_a?(ProcLiteral) %}
                    \{% if scope.args.empty? %}
                      relation = relation.\{{scope.body}}
                    \{% else %}
                      relation = \{{scope}}.call(relation)
                    \{% end %}
                  \{% end %}
                  restriction.try(&.each { |condition| relation.where_fields << condition })
                  Grant::AssociationLoader.where_in(relation, \{{ann[:primary_key].id.stringify}}, values).select.map(&.as(Grant::Base))
                }
                Grant::AssociationLoader.preload_belongs_to(
                  records, assoc_name, \{{ann[:foreign_key].id.stringify}}, \{{ann[:primary_key].id.stringify}}, loader)
              \{% end %}
            \{% elsif ann[:type] == :has_one && ann[:through] && !ann[:through_association] %}
              # Legacy `through:` naming a table: no batch form exists, so each
              # record resolves through its own reader (correct, one query each).
              records.each do |record|
                record.set_loaded_association(assoc_name, record.as(\{{@type}}).\{{method.name.id}})
              end
            \{% elsif ann[:through] %}
              \{% through_name = ann[:through].id.stringify %}
              \{% through_method = nil %}
              \{% for candidate_type in [@type] + @type.ancestors.select { |ancestor| ancestor.class? && ancestor < Grant::Base } %}
                \{% for candidate in candidate_type.methods %}
                  \{% if !through_method && candidate.name.stringify == through_name && candidate.annotation(Grant::Relationship) %}
                    \{% through_method = candidate %}
                  \{% end %}
                \{% end %}
              \{% end %}
              \{% through_ann = through_method ? through_method.annotation(Grant::Relationship) : nil %}
              \{% join_model = through_ann && through_ann[:target].resolve? && !through_ann[:polymorphic] ? through_ann[:target].resolve : nil %}
              \{% source_name = ann[:source].id.stringify %}
              \{% source_method = nil %}
              \{% if join_model %}
                \{% for candidate_type in [join_model] + join_model.ancestors.select { |ancestor| ancestor.class? && ancestor < Grant::Base } %}
                  \{% for candidate in candidate_type.methods %}
                    \{% if !source_method && candidate.name.stringify == source_name && candidate.annotation(Grant::Relationship) %}
                      \{% source_method = candidate %}
                    \{% end %}
                  \{% end %}
                \{% end %}
              \{% end %}
              \{% source_ann = source_method ? source_method.annotation(Grant::Relationship) : nil %}
              \{% unless join_model && source_ann && source_ann[:target].resolve? && !source_ann[:polymorphic] %}
                \{% raise "Cannot preload through association #{@type}##{method.name}; declare a resolvable through and source association" %}
              \{% end %}
              \{% through_belongs = through_ann[:type] == :belongs_to %}
              \{% source_belongs = source_ann[:type] == :belongs_to %}
              join_loader = ->(values : Array(Grant::Columns::Type)) : Array(Grant::Base) {
                Grant::AssociationLoader.where_in(\{{join_model}}.current_scope, \{{(through_belongs ? through_ann[:primary_key] : through_ann[:foreign_key]).id.stringify}}, values).select.map(&.as(Grant::Base))
              }
              target_loader = ->(values : Array(Grant::Columns::Type)) : Array(Grant::Base) {
                relation = \{{target}}.current_scope
                \{% if scope.is_a?(ProcLiteral) %}
                  \{% if scope.args.empty? %}
                    relation = relation.\{{scope.body}}
                  \{% else %}
                    relation = \{{scope}}.call(relation)
                  \{% end %}
                \{% end %}
                Grant::AssociationLoader.where_in(relation, \{{(source_belongs ? source_ann[:primary_key] : source_ann[:foreign_key]).id.stringify}}, values).select.map(&.as(Grant::Base))
              }
              Grant::AssociationLoader.preload_through(
                records, assoc_name,
                \{{(through_belongs ? through_ann[:foreign_key] : through_ann[:primary_key]).id.stringify}},
                \{{(through_belongs ? through_ann[:primary_key] : through_ann[:foreign_key]).id.stringify}},
                \{{(source_belongs ? source_ann[:foreign_key] : source_ann[:primary_key]).id.stringify}},
                \{{(source_belongs ? source_ann[:primary_key] : source_ann[:foreign_key]).id.stringify}},
                join_loader, target_loader, \{{ann[:type] == :has_many}})
            \{% else %}
              loader = ->(values : Array(Grant::Columns::Type)) : Array(Grant::Base) {
                relation = \{{target}}.current_scope
                \{% if scope.is_a?(ProcLiteral) %}
                  \{% if scope.args.empty? %}
                    relation = relation.\{{scope.body}}
                  \{% else %}
                    relation = \{{scope}}.call(relation)
                  \{% end %}
                \{% end %}
                \{% if ann[:polymorphic_as] %}
                  relation = relation.where(\{{ann[:type_column].id.stringify}}, :eq, \{{@type}}.polymorphic_name)
                \{% end %}
                restriction.try(&.each { |condition| relation.where_fields << condition })
                Grant::AssociationLoader.where_in(relation, \{{ann[:foreign_key].id.stringify}}, values).select.map(&.as(Grant::Base))
              }
              Grant::AssociationLoader.preload_has(
                records, assoc_name, \{{ann[:primary_key].id.stringify}}, \{{ann[:foreign_key].id.stringify}},
                loader, \{{ann[:type] == :has_many}})
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
    include Grant::Reflection::ClassMethods

    def strict_loading(value : Bool = true) : Grant::Query::Builder(self)
      query = get_query_builder
      query.strict_loading(value)
      query
    end

    # Makes every record of this model strict loading. Setting it on
    # `Grant::Base` makes it the default for every model that does not set its
    # own (subclasses do not inherit a parent model's setting).
    #
    # ```
    # User.strict_loading_by_default = true
    # ```
    def strict_loading_by_default=(value : Bool)
      Grant::EagerLoading.store_strict_loading_default(self.name, value)
    end

    def strict_loading_by_default : Bool
      Grant::EagerLoading.strict_loading_default_for(self.name)
    end

    # The class name stored in the type column of a polymorphic association that
    # points at this model. Defaults to the class name; STI models store the
    # root class name, matching ActiveRecord's `polymorphic_name`. Override it to
    # store another string.
    def polymorphic_name : String
      self.name
    end

    def includes(*associations, **nested_associations)
      get_query_builder.includes(*associations, **nested_associations)
    end

    def preload(*associations, **nested_associations)
      get_query_builder.preload(*associations, **nested_associations)
    end

    def eager_load(*associations, **nested_associations)
      get_query_builder.eager_load(*associations, **nested_associations)
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
