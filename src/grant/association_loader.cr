module Grant
  # Loads associations for records that are already in memory, one query per
  # association level: this is what `includes`, `preload`, and `eager_load` run
  # after the main query, and what `Grant::Preloader` exposes directly.
  class AssociationLoader
    # Fetches the target records whose key column is in the given values. The
    # association macros build one per association, closing over the concrete
    # target class, the association scope, and the target's default scope.
    alias BatchLoader = Proc(Array(Grant::Columns::Type), Array(Grant::Base))

    # Runs one model's generated `_eager_batch_load` for records of that model.
    alias BatchDispatcher = Proc(Array(Grant::Base), String, Array(Grant::Query::WhereField)?, Bool)

    # A model's dispatcher and the test for records it can load (the model and
    # its STI subclasses).
    alias Dispatch = NamedTuple(handles: Proc(Grant::Base, Bool), call: BatchDispatcher)

    # Per-model dispatchers, published copy-on-write like the association
    # registry. A model is added by `enable`, which only code that can load
    # associations calls (`includes`/`preload`/`eager_load`, `Grant::Preloader`,
    # and the loaders the association macros generate for their targets). The
    # loader never calls `_eager_batch_load` through `Grant::Base`, so a query
    # without association loading does not make every model's loader reachable
    # to the compiler.
    @@dispatchers = {} of String => Dispatch
    @@dispatchers_mutex = Mutex.new

    # Makes *model* (and its STI subclasses) loadable by the association loader.
    # Idempotent and cheap after the first call.
    def self.enable(model : M.class) : Nil forall M
      return if @@dispatchers.has_key?(M.name)
      dispatch = {
        handles: ->(record : Grant::Base) : Bool { record.is_a?(M) },
        call:    ->(records : Array(Grant::Base), name : String, restriction : Array(Grant::Query::WhereField)?) : Bool {
          records.first.as(M)._eager_batch_load(records, name, restriction)
        },
      }
      @@dispatchers_mutex.synchronize do
        updated = @@dispatchers.dup
        updated[M.name] = dispatch
        @@dispatchers = updated
      end
    end

    # True when *model* was enabled (see `enable`).
    def self.enabled?(model : M.class) : Bool forall M
      @@dispatchers.has_key?(M.name)
    end

    # Loads *name* on *records* (all of one class) with the dispatcher enabled
    # for that class or an ancestor of it. Returns false when the association
    # is unknown to the model.
    def self.batch_load(records : Array(Grant::Base), name : String,
                        restriction : Array(Grant::Query::WhereField)? = nil) : Bool
      first = records.first
      dispatch = @@dispatchers[first.class.name]? || @@dispatchers.each_value.find(&.[:handles].call(first))
      raise Grant::PreloadNotEnabledError.new(first.class.name) unless dispatch
      # A proc takes the exact array type, where a method takes any subtype.
      batch = records.map { |record| record.as(Grant::Base) }
      dispatch[:call].call(batch, name, restriction)
    end

    # Loads every association in *associations* (recursively) on *records*.
    # Records that already have an association loaded are skipped for it, and
    # records of different classes (polymorphic or STI results) are loaded per
    # class. Raises `Grant::AssociationNotFoundError` for an unknown name.
    #
    # *restrictions* holds, per top-level association, WHERE conditions to add
    # to the query that loads it (see `Grant::Query::Builder#eager_load`).
    def self.load_associations(records : Array(Grant::Base), associations : Array(Grant::Includes),
                               restrictions : Hash(Symbol, Array(Grant::Query::WhereField))? = nil)
      return if records.empty? || associations.empty?

      associations.each do |association|
        case association
        when Symbol
          load_single_association(records, association, restrictions.try(&.[association]?))
        when Hash
          association.each do |name, nested|
            load_single_association(records, name, restrictions.try(&.[name]?))
            nested_records = records.flat_map { |record| extract_association_records(record, name) }
            load_associations(nested_records, nested)
          end
        end
      end
    end

    # Normalizes the argument forms `includes` accepts (`:a`, `[:a, :b]`,
    # `a: :b`, `a: {b: :c}`, hashes) into the recursive `Includes` list.
    def self.normalize(spec : Symbol) : Array(Grant::Includes)
      [spec.as(Grant::Includes)]
    end

    def self.normalize(spec : Array) : Array(Grant::Includes)
      list = [] of Grant::Includes
      spec.each { |item| list.concat(normalize(item)) }
      list
    end

    def self.normalize(spec : Hash | NamedTuple) : Array(Grant::Includes)
      list = [] of Grant::Includes
      spec.each do |name, nested|
        list << {name => normalize(nested)}.as(Grant::Includes)
      end
      list
    end

    # ---- batch distribution, called from the generated `_eager_batch_load` ----

    def self.preload_belongs_to(records : Array(Grant::Base), name : String, foreign_key : String,
                                primary_key : String, loader : BatchLoader) : Nil
      key_values = key_values(records, foreign_key)
      lookup = {} of Grant::Columns::Type => Grant::Base
      unless key_values.empty?
        loader.call(key_values).each { |target| lookup[target.read_attribute(primary_key)] = target }
      end
      inverse = singular_inverse(records, name)
      records.each do |record|
        target = lookup[record.read_attribute(foreign_key)]?
        record.set_loaded_association(name, target)
        record._adopt_strict_loading(target, false)
        if target && inverse
          target.set_loaded_association(inverse, record)
        end
      end
    end

    def self.preload_has(records : Array(Grant::Base), name : String, primary_key : String,
                         foreign_key : String, loader : BatchLoader, collection : Bool) : Nil
      owner_values = key_values(records, primary_key)
      grouped = {} of Grant::Columns::Type => Array(Grant::Base)
      unless owner_values.empty?
        loader.call(owner_values).each do |target|
          (grouped[target.read_attribute(foreign_key)] ||= [] of Grant::Base) << target
        end
      end
      inverse = records.first?.try(&._association_inverse(name))
      records.each do |record|
        found = grouped[record.read_attribute(primary_key)]?
        if collection
          targets = found || [] of Grant::Base
          record.set_loaded_association(name, targets)
          targets.each do |target|
            record._adopt_strict_loading(target, true)
            target.set_loaded_association(inverse, record) if inverse
          end
        else
          target = found.try(&.first?)
          record.set_loaded_association(name, target)
          record._adopt_strict_loading(target, false)
          target.set_loaded_association(inverse, record) if target && inverse
        end
      end
    end

    # Two hops: join rows whose *join_owner_key* matches the owners'
    # *owner_key*, then targets whose *target_key* matches the join rows'
    # *join_target_key*.
    def self.preload_through(records : Array(Grant::Base), name : String,
                             owner_key : String, join_owner_key : String,
                             join_target_key : String, target_key : String,
                             join_loader : BatchLoader, target_loader : BatchLoader,
                             collection : Bool) : Nil
      owner_values = key_values(records, owner_key)
      join_rows = owner_values.empty? ? [] of Grant::Base : join_loader.call(owner_values)
      join_by_owner = {} of Grant::Columns::Type => Array(Grant::Base)
      join_rows.each do |join_row|
        (join_by_owner[join_row.read_attribute(join_owner_key)] ||= [] of Grant::Base) << join_row
      end
      target_values = key_values(join_rows, join_target_key)
      targets = target_values.empty? ? [] of Grant::Base : target_loader.call(target_values)
      targets_by_key = {} of Grant::Columns::Type => Array(Grant::Base)
      targets.each do |target|
        (targets_by_key[target.read_attribute(target_key)] ||= [] of Grant::Base) << target
      end
      records.each do |record|
        associated = [] of Grant::Base
        join_by_owner[record.read_attribute(owner_key)]?.try &.each do |join_row|
          key = join_row.read_attribute(join_target_key)
          next if key.nil?
          targets_by_key[key]?.try { |found| associated.concat(found) }
        end
        if collection
          record.set_loaded_association(name, associated)
          associated.each { |target| record._adopt_strict_loading(target, true) }
        else
          target = associated.first?
          record.set_loaded_association(name, target)
          record._adopt_strict_loading(target, false)
        end
      end
    end

    def self.preload_polymorphic_belongs_to(records : Array(Grant::Base), name : String, foreign_key : String,
                                            type_column : String, primary_key : String?) : Nil
      ids_by_type = {} of String => Array(Grant::Columns::Type)
      records.each do |record|
        type_name = record.read_attribute(type_column)
        target_id = record.read_attribute(foreign_key)
        if type_name.is_a?(String) && !target_id.nil?
          (ids_by_type[type_name] ||= [] of Grant::Columns::Type) << target_id
        end
      end
      # Keys are compared as text so a String (or UUID) foreign key column can
      # point at targets whose primary key is numeric or a UUID.
      lookup = {} of Tuple(String, String) => Grant::Base
      ids_by_type.each do |type_name, ids|
        Grant::Polymorphic.load_polymorphic_batch(type_name, primary_key, ids.uniq).each do |target|
          key = primary_key ? target.read_attribute(primary_key) : Grant::Polymorphic.primary_key_of(target)
          lookup[{type_name, key.to_s}] = target
        end
      end
      records.each do |record|
        type_name = record.read_attribute(type_column)
        target_id = record.read_attribute(foreign_key)
        target = if type_name.is_a?(String) && !target_id.nil?
                   lookup[{type_name, target_id.to_s}]?
                 end
        record.set_loaded_association(name, target)
        record._adopt_strict_loading(target, false)
      end
    end

    # Restricts *relation* to rows whose *column* is in *values*. The query
    # builder takes homogeneous lists, so the (uniform) key values are narrowed
    # to their concrete type first; lists longer than
    # `Grant.settings.in_clause_limit` are chunked by the builder.
    def self.where_in(relation : Grant::Query::Builder(M), column : String,
                      values : Array(Grant::Columns::Type)) : Grant::Query::Builder(M) forall M
      case values.first?
      when Int64  then relation.where(column, :in, values.map(&.as(Int64)))
      when Int32  then relation.where(column, :in, values.map(&.as(Int32)))
      when Int16  then relation.where(column, :in, values.map(&.as(Int16)))
      when String then relation.where(column, :in, values.map(&.as(String)))
      when UUID   then relation.where(column, :in, values.map(&.as(UUID)))
      when Nil    then relation.where("1 = 0")
      else
        raise ArgumentError.new("Cannot load associations by #{values.first.class} keys")
      end
    end

    # Distinct non-nil values of *key* across *records*, in first-seen order.
    def self.key_values(records : Array(Grant::Base), key : String) : Array(Grant::Columns::Type)
      seen = Set(Grant::Columns::Type).new
      values = [] of Grant::Columns::Type
      records.each do |record|
        value = record.read_attribute(key)
        values << value if !value.nil? && seen.add?(value)
      end
      values
    end

    private def self.load_single_association(records : Array(Grant::Base), association_name : Symbol,
                                             restriction : Array(Grant::Query::WhereField)? = nil)
      records.group_by(&.class).each_value do |group|
        pending = group.reject(&.association_loaded?(association_name))
        next if pending.empty?
        # Delegate to the per-model instance method generated in
        # `Grant::EagerLoading`, which knows the concrete target classes.
        unless batch_load(pending, association_name.to_s, restriction)
          raise Grant::AssociationNotFoundError.new(pending.first.class.name, association_name.to_s)
        end
      end
    end

    # The inverse of a `belongs_to`, when it is a `has_one` on the target
    # (a `has_many` has no single record to point back at).
    private def self.singular_inverse(records : Array(Grant::Base), name : String) : String?
      owner = records.first? || return nil
      reflection = Grant::AssociationRegistry.reflection(owner.class.name, name) || return nil
      inverse = reflection.inverse_of || return nil
      inverse.has_one? ? inverse.name : nil
    end

    private def self.extract_association_records(record : Grant::Base, association_name : Symbol)
      data = record.get_loaded_association(association_name)
      case data
      when Array(Grant::Base)
        data
      when Grant::Base
        [data]
      else
        [] of Grant::Base
      end
    end
  end

  # Loads associations on records that are already in memory (ActiveRecord's
  # `ActiveRecord::Associations::Preloader`). Associations that are already
  # loaded on a record are not queried again.
  #
  # ```
  # users = User.all.to_a
  # Grant::Preloader.new(users, [:posts, {comments: [:author]}]).call
  # users.first.posts # no query
  # ```
  class Preloader
    getter records : Array(Grant::Base)
    getter associations : Array(Grant::Includes)

    def initialize(records : Array(T), *associations, **nested_associations) forall T
      {% for model in T.union_types %}
        Grant::AssociationLoader.enable({{model}})
      {% end %}
      @records = [] of Grant::Base
      records.each { |record| @records << record }
      @associations = [] of Grant::Includes
      associations.each { |spec| @associations.concat(Grant::AssociationLoader.normalize(spec)) }
      @associations.concat(Grant::AssociationLoader.normalize(nested_associations)) unless nested_associations.empty?
    end

    # Runs the loading and returns the records.
    def call : Array(Grant::Base)
      Grant::AssociationLoader.load_associations(@records, @associations)
      @records
    end
  end
end
