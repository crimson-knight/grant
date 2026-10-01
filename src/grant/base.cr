require "./collection"
require "./association_collection"
require "./loaded_association_collection"
require "./associations"
require "./callbacks"
require "./columns"
require "./dirty"
require "./columns_helpers"
require "./query/executors/base"
require "./query/**"
require "./query_extensions"
require "./enum_attributes"
require "./convenience_methods"
require "./bulk_operations"
require "./settings"
require "./table"
require "./transactions"
require "./timestamps"
require "./readonly"
require "./counters"
require "./record_copy"
require "./transaction"
require "./locking"
require "./locking/pessimistic"
require "./locking/optimistic"
require "./validators"
require "./validators/**"
require "./validation_helpers/**"
require "./migrator"
require "./select"
require "./version"
require "./connections"
require "./integrators"
require "./converters"
require "./serializers/jsonb"
require "./type"
require "./connection_management"
require "./eager_loading"
require "./association_loader"
require "./commit_callbacks"
require "./scoping"
require "./query_cache"
require "./attribute_api"
require "./logging"
require "./query_analysis"
require "./composite_primary_key"
require "./secure_token"
require "./signed_id"
require "./token_for"
require "./serialized_column"
require "./store_accessor"
require "./normalization"
require "./nested_attributes"
require "./async"
require "./aggregations"
require "./value_objects"
require "./encryption"
require "./attributes"
require "./integration"

# Grant::Base is the base class for your model objects.
abstract class Grant::Base
  # Dirty tracking storage - using a union of all possible types
  # We use a broad union type to handle all column types including enums
  alias DirtyValue = Nil | Bool | Int32 | Int64 | Float32 | Float64 | String | Time | UUID | Slice(UInt8) | Array(String) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Float32) | Array(Float64) | Array(Bool) | Array(UUID)

  # Keyword attributes as the one String-keyed hash `set_attributes` reads,
  # built in a single pass (`args.to_h.transform_keys(&.to_s)` builds two).
  #
  # :nodoc:
  def self.__string_keyed_attributes(args : T) forall T
    {% if T.keys.empty? %}
      {} of String => Grant::Columns::Type
    {% else %}
      hash = Hash(String, typeof(args.values.to_a.first)).new(initial_capacity: args.size)
      args.each { |key, value| hash[key.to_s] = value }
      hash
    {% end %}
  end

  include Associations
  include Callbacks
  include Columns
  include Dirty
  include Tables
  include Transactions
  include Timestamps
  include Readonly
  include RecordCopy
  include Validators
  include ValidationHelpers
  include Migrator
  include Select
  include Querying
  include EagerLoading
  include CommitCallbacks
  include Scoping

  include ConnectionManagement
  include AttributeApi
  include SerializedColumn
  include NestedAttributes
  include ValueObjects
  include Encryption::Model
  include Attributes
  include Integration
  include Locking::Pessimistic
  include Transaction

  # Make secure token macros available
  macro has_secure_token(name, length = 24, alphabet = :base58, on = :create)
    Grant::SecureToken.has_secure_token({{ name }}, {{ length }}, {{ alphabet }}, {{ on }})

    # Token columns are credentials: `inspect` prints them as [FILTERED].
    {% if @type.has_constant?(:GRANT_SECURE_TOKEN_COLUMNS) %}
      {% token_columns = @type.constant(:GRANT_SECURE_TOKEN_COLUMNS) %}
      {% token_columns << name.id.stringify %}
    {% else %}
      {% token_columns = [name.id.stringify] %}
      GRANT_SECURE_TOKEN_COLUMNS = {{ token_columns }}
    {% end %}

    def self.secure_token_column?(name : String) : Bool
      case name
      {% for token_column in token_columns %}
      when {{ token_column }}
        true
      {% end %}
      else
        false
      end
    end
  end

  # Auto-register class for polymorphic associations will be handled in the main inherited macro

  extend Columns::ClassMethods
  extend Dirty::ClassMethods
  extend Tables::ClassMethods
  extend Grant::Migrator::ClassMethods

  extend Querying::ClassMethods
  extend Query::BuilderMethods
  extend Grant::Transactions::ClassMethods
  extend Grant::Timestamps::ClassMethods
  extend Grant::Readonly::ClassMethods
  extend Grant::Counters::ClassMethods
  extend Grant::Transaction::ClassMethods
  extend Integrators
  extend Select
  extend EagerLoading::ClassMethods
  extend Scoping::ClassMethods
  extend QueryCache::ClassMethods
  extend Grant::Async::ClassMethods
  extend Grant::Aggregations::ClassMethods
  extend ValueObjects::ClassMethods
  extend Attributes::ClassMethods
  extend Integration::ClassMethods

  # Serialization support is included on the abstract base itself (not only on
  # concrete subclasses via `inherited`) so that the abstract `Grant::Base` type
  # — to which Crystal widens a union of two-or-more subclasses (`Grant::Base+`)
  # — satisfies `JSON::Serializable` / `YAML::Serializable`. Without this, any
  # context expecting `YAML::Serializable?` (e.g. Amber's
  # `Amber::Configuration::CustomRegistry#load_custom_from_yaml`) fails to
  # compile the moment a program defines two models. See issues #39/#41.
  include JSON::Serializable
  include YAML::Serializable

  # `Grant::Base` is abstract and is never (de)serialized directly: every real
  # model is a concrete subclass that regenerates fully-working serializers via
  # the `include`s in `macro inherited` below. The auto-generated serializers the
  # two `include`s above install on the *abstract* base reference per-subclass
  # column ivars (e.g. `@id`) that do not exist on `Grant::Base` itself, which
  # would otherwise fail to type-infer when `Grant::Base+.from_yaml` is realized.
  # We override them here with abstract-safe stubs so the abstract base satisfies
  # the `JSON/YAML::Serializable` *type* without instantiating a broken concrete
  # serializer. See issues #39/#41.
  protected def self.new(ctx : ::YAML::ParseContext, node : ::YAML::Nodes::Node)
    raise "Grant::Base is abstract and cannot be deserialized directly; deserialize a concrete subclass instead"
  end

  protected def self.new(pull : ::JSON::PullParser)
    raise "Grant::Base is abstract and cannot be deserialized directly; deserialize a concrete subclass instead"
  end

  def initialize(*, __context_for_yaml_serializable ctx : ::YAML::ParseContext, __node_for_yaml_serializable node : ::YAML::Nodes::Node)
    raise "Grant::Base is abstract and cannot be deserialized directly; deserialize a concrete subclass instead"
  end

  def initialize(*, __pull_for_json_serializable pull : ::JSON::PullParser)
    raise "Grant::Base is abstract and cannot be deserialized directly; deserialize a concrete subclass instead"
  end

  # Returns `true` if this record has **not** yet been saved to the database
  # (i.e. it was built in memory and never `INSERT`ed), `false` once it has been
  # persisted. The inverse of `#persisted?` for a non-destroyed record.
  #
  # The backing flag is flipped to `false` after a successful `save`/`create`.
  #
  # ```
  # user = User.new(email: "a@example.com")
  # user.new_record? # => true
  # user.save
  # user.new_record? # => false
  # ```
  #
  # NOTE: the concrete implementation (and its `new_record=` setter) is generated
  # per model by Grant. This declaration exists so the method is documented and
  # type-visible on the abstract base.
  abstract def new_record? : Bool

  # Returns `true` if this record has been destroyed (its row deleted via
  # `#destroy`), `false` otherwise. A destroyed in-memory instance is frozen
  # against further persistence.
  #
  # ```
  # user = User.find!(1)
  # user.destroyed? # => false
  # user.destroy
  # user.destroyed? # => true
  # ```
  #
  # NOTE: the concrete implementation is generated per model by Grant. This
  # declaration exists so the method is documented and type-visible on the
  # abstract base.
  abstract def destroyed? : Bool

  # Returns `true` if this record exists in the database — that is, it is neither
  # a brand-new unsaved record nor a destroyed one. Equivalent to
  # `!(new_record? || destroyed?)`. Mirrors ActiveRecord's `persisted?`.
  #
  # ```
  # user = User.new(email: "a@example.com")
  # user.persisted? # => false  (new, unsaved)
  # user.save
  # user.persisted? # => true   (now in the database)
  # user.destroy
  # user.persisted? # => false  (destroyed)
  # ```
  def persisted? : Bool
    !(new_record? || destroyed?)
  end

  # True once the record is destroyed. A destroyed record is frozen against
  # further persistence: `save`, `update`, `touch` and friends raise
  # `Grant::RecordDestroyedError`. Mirrors ActiveRecord's `frozen?` after
  # `destroy`.
  def frozen? : Bool
    destroyed?
  end

  # The primary key value that identifies this record, or `nil` when it has none
  # yet (a new record). Composite keys yield an array of their parts.
  #
  # :nodoc:
  def __identity_key : Grant::Columns::Type | Array(Grant::Columns::Type)
    {% if @type.abstract? %}
      nil
    {% elsif @type.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] }.size > 1 %}
      parts = primary_key_values.values
      parts.any?(&.nil?) ? nil : parts
    {% else %}
      primary_key_value.as(Grant::Columns::Type)
    {% end %}
  end

  # The class that scopes identity: the STI root for single table inheritance
  # hierarchies, otherwise the record's own class.
  #
  # :nodoc:
  def __identity_class_name : String
    {% if @type.abstract? %}
      self.class.name
    {% elsif @type.ancestors.any? { |ancestor| ancestor.stringify == "Grant::STI" } %}
      self.class.sti_root.name
    {% else %}
      self.class.name
    {% end %}
  end

  # Two records are equal when they are the same object, or when they belong to
  # the same table (the same class, or the same STI hierarchy) and share a
  # present primary key. Records without a primary key (new records) are only
  # equal to themselves. Mirrors ActiveRecord's `==`.
  #
  # ```
  # User.find!(1) == User.find!(1) # => true
  # User.new == User.new           # => false
  # ```
  def ==(other : Grant::Base) : Bool
    return true if same?(other)
    key = __identity_key
    return false if key.nil?
    return false unless __identity_class_name == other.__identity_class_name
    key == other.__identity_key
  end

  # Hashes by class and primary key so equal records collapse in a `Set`,
  # `uniq` and as `Hash` keys. A record without a primary key hashes by
  # identity, and so changes hash once it is saved (as in ActiveRecord).
  def hash(hasher)
    key = __identity_key
    if key.nil?
      super
    else
      hasher = __identity_class_name.hash(hasher)
      key.hash(hasher)
    end
  end

  # The names of this class and its model superclasses, nearest first. Used to
  # match `no_touching` / `suppress` blocks declared on a parent class.
  #
  # :nodoc:
  def self.__lineage_names : Array(String)
    [] of String
  end

  macro inherited
    # :nodoc:
    def self.__lineage_names : Array(String)
      [{{@type.name.stringify}}] + {{@type.superclass}}.__lineage_names
    end

    # Connection settings belong to each model class and resolve through the
    # superclass chain when read, so a `connects_to` on a parent (usually an
    # abstract class) reaches subclasses declared before and after it.
    # :nodoc:
    def self.default_database_name : String
      @@own_default_database_name || {{@type.superclass}}.default_database_name
    end

    # :nodoc:
    def self.connection_config : Hash(Symbol, String)
      @@own_connection_config || {{@type.superclass}}.connection_config
    end

    # :nodoc:
    def self.shard_config : Hash(Symbol, Hash(Symbol, String))
      @@own_shard_config || {{@type.superclass}}.shard_config
    end

    # :nodoc:
    def self.__connection_owned_by?(owner : String) : Bool
      owner == {{@type.name.stringify}} || {{@type.superclass}}.__connection_owned_by?(owner)
    end

    # Keep this method concrete per model. A shared class method invoked through
    # `Grant::Base.class` gives `self` a union of model classes; dispatching a
    # model-specific default-scope method from that union triggers an LLVM bug
    # in Crystal 1.21. The per-model method keeps Builder's model type concrete
    # and still lets generic class references dispatch to the right scope.
    # :nodoc:
    def self.__builder : Grant::Query::Builder({{@type}})
      resolved_adapter = adapter
      db_type = if resolved_adapter.postgres?
                  Grant::Query::Builder::DbType::Pg
                elsif resolved_adapter.mysql?
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end

      Grant::Query::Builder({{@type}}).new(db_type)
    end

    def self.current_scope : Grant::Query::Builder({{@type}})
      if scoped = Grant::Scoping.current_relation({{@type}})
        return scoped
      end

      # `__builder` may be overridden by the sharding macro and Crystal sees
      # the union of builders from STI siblings here. Cast back to this model's
      # builder type while retaining the sharded subclass at runtime.
      query = __builder.as(Grant::Query::Builder({{@type}}))

      if !_unscoped? && _has_default_scope?
        query = apply_default_scope(query)
        query = query.promote_where_to_default_scope
      end

      if __sti_model? && !sti_root_class?
        names = sti_names_for_query
        query = if names.size == 1
                  query.where(inheritance_column, :eq, names.first)
                else
                  query.where(inheritance_column, :in, names)
                end
        query = query.promote_where_to_default_scope
      end

      # A `scoping { }` block of a parent class (single table inheritance)
      # applies to this class too.
      if Fiber.current.grant_scoping_stacks && !_unscoped?
        query = Grant::Scoping.merge_inherited(query, __lineage_names)
      end

      query
    end

    # The annotated ivars below — and the auto-generated JSON/YAML serializers —
    # may only be declared ONCE per inheritance chain. Crystal raises
    # "can't annotate @x ... because it was first defined in <Super>" if an
    # annotated ivar is re-declared in a subclass. To support multi-level
    # inheritance (Single Table Inheritance: `Car < Vehicle < Grant::Base`),
    # these once-only declarations run only for *first-level* subclasses (whose
    # direct superclass is `Grant::Base`); deeper subclasses inherit them.
    # See issues #39/#41 and the STI work.
    {% if @type.superclass.id == "Grant::Base" %}
      # Regenerate fully-working, per-subclass JSON/YAML serializers that see this
      # concrete model's own column ivars. See issues #39/#41.
      include JSON::Serializable
      include YAML::Serializable

      # Concrete per-model backing for `#new_record?` / `#new_record=`.
      # Documented on the abstract `Grant::Base` via `abstract def new_record?`.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      property? new_record : Bool = true

      # Concrete per-model backing for `#destroyed?`. Documented on the abstract
      # `Grant::Base` via `abstract def destroyed?`.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      getter? destroyed : Bool = false

      private def mark_destroyed
        @destroyed = true
      end

      private def restore_destroyed_state(value : Bool)
        @destroyed = value
      end

      # Backing flag for record-level read-only marking. When true, attempts to
      # persist an update (or destroy) raise `Grant::ReadOnlyRecordError`.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @readonly : Bool = false

      # `#persisted?` is defined once on the abstract `Grant::Base` (it only
      # depends on `#new_record?` / `#destroyed?`), so it is not regenerated here.

      # Returns `true` if this record has been marked read-only (via `#readonly!`
      # or by being loaded through a read-only relation), `false` otherwise.
      # Read-only records raise `Grant::ReadOnlyRecordError` on update or
      # destroy.
      #
      # ```
      # class User < Grant::Base
      #   column id : Int64, primary: true
      #   column email : String
      # end
      #
      # user = User.find!(1)
      # user.readonly? # => false
      # user.readonly!
      # user.readonly? # => true
      # ```
      def readonly? : Bool
        @readonly
      end

      # Marks this record as read-only and returns `nil`. After this, attempts to
      # update or destroy it raise `Grant::ReadOnlyRecordError` — useful for
      # passing a record around with a guarantee it won't be mutated in the DB.
      # Mirrors ActiveRecord's `readonly!`.
      #
      # ```
      # user = User.find!(1)
      # user.readonly!
      # user.update(email: "x@example.com") # raises Grant::ReadOnlyRecordError
      # ```
      def readonly! : Nil
        @readonly = true
      end

      # Sets the read-only state of this record to *value* (default `true`) and
      # returns `nil`. Intended for query/relation loaders that hydrate records
      # as part of a read-only relation; pass `false` to clear the flag.
      #
      # ```
      # user.mark_readonly        # equivalent to user.readonly!
      # user.mark_readonly(false) # clear the read-only flag
      # ```
      def mark_readonly(value : Bool = true) : Nil
        @readonly = value
      end

      # Dirty tracking storage - using a union of all possible types
      # We use a broad union type to handle all column types including enums

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @original_attributes : Hash(String, DirtyValue)?

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @changed_attributes : Hash(String, Tuple(DirtyValue, DirtyValue))?

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @previous_changes : Hash(String, Tuple(DirtyValue, DirtyValue))?

      # Attributes flagged by `attribute_will_change!`; their pending change is
      # re-read on demand so in-place edits after the flag are reflected.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @forced_changes : Set(String)?

      # True while `initialize` assigns the attributes it was given: those
      # assignments are the record's starting values, not changes, so the
      # setters skip dirty tracking and no dirty hashes are built for them.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @dirty_tracking_suspended : Bool = false
    {% else %}
      # Deeper subclass (STI): regenerate per-subclass JSON/YAML serializers so
      # they see this concrete model's own (inherited + added) column ivars,
      # without re-declaring the inherited annotated ivars above.
      include JSON::Serializable
      include YAML::Serializable
    {% end %}

    protected class_getter select_container : Container = Container.new(table_name: table_name, fields: fields)

    # Auto-register for polymorphic associations
    Grant::Polymorphic.register_polymorphic_type({{@type.name.stringify}}, {{@type}})

    # The names flagged by `attribute_will_change!`, created on first use.
    private def forced_change_names : Set(String)
      @forced_changes ||= Set(String).new
    end

    # Ensure dirty tracking hashes are initialized
    private def ensure_dirty_tracking_initialized
      @original_attributes ||= {} of String => DirtyValue
      @changed_attributes ||= {} of String => Tuple(DirtyValue, DirtyValue)
      @previous_changes ||= {} of String => Tuple(DirtyValue, DirtyValue)
    end

    # The original-value hash, created on the first change of a column.
    private def dirty_originals : Hash(String, DirtyValue)
      @original_attributes ||= {} of String => DirtyValue
    end

    # The pending-change hash, created on the first change of a column.
    private def dirty_pending : Hash(String, Tuple(DirtyValue, DirtyValue))
      @changed_attributes ||= {} of String => Tuple(DirtyValue, DirtyValue)
    end

    # True once any dirty hash exists. A record that was loaded and never
    # assigned a column has none.
    #
    # :nodoc:
    def __dirty_tracking_allocated? : Bool
      !(@original_attributes.nil? && @changed_attributes.nil? && @previous_changes.nil?)
    end

    # Narrows the initialized nullable ivars together for operations that need
    # to clear or snapshot all dirty tracking state.
    private def dirty_tracking_hashes : Tuple(
      Hash(String, DirtyValue),
      Hash(String, Tuple(DirtyValue, DirtyValue)),
      Hash(String, Tuple(DirtyValue, DirtyValue)),
    )
      ensure_dirty_tracking_initialized
      original_attributes = @original_attributes || {} of String => DirtyValue
      changed_attributes = @changed_attributes || {} of String => Tuple(DirtyValue, DirtyValue)
      previous_changes = @previous_changes || {} of String => Tuple(DirtyValue, DirtyValue)
      @original_attributes = original_attributes
      @changed_attributes = changed_attributes
      @previous_changes = previous_changes
      {original_attributes, changed_attributes, previous_changes}
    end

    # Hook for JSON/YAML deserialization
    def after_initialize
      ensure_dirty_tracking_initialized
    end

    macro finished
      # Builds a new (unsaved) record from keyword arguments, one per column.
      # The record is in memory only until you call `#save`/`#save!` (or use
      # `.create`/`.create!`, which build and save in one step).
      #
      # ```
      # user = User.new(email: "a@example.com", name: "Ada")
      # user.new_record? # => true
      # user.save        # INSERTs the row
      # ```
      def initialize(**args)
        @dirty_tracking_suspended = true
        __apply_scope_attributes
        __set_named_attributes(args)
        @dirty_tracking_suspended = false
        establish_initial_dirty_baseline
        __after_initialize
      end

      # Builds a new (unsaved) record from a pre-built attributes hash
      # (`Grant::ModelArgs` — a `Hash(String | Symbol, Grant::Columns::Type)`).
      # Useful when the attributes are assembled dynamically (e.g. from params).
      #
      # ```
      # attrs = {"email" => "a@example.com", "name" => "Ada"}
      # user = User.new(attrs)
      # user.save
      # ```
      def initialize(args : Grant::ModelArgs)
        @dirty_tracking_suspended = true
        __apply_scope_attributes
        set_attributes(args.transform_keys(&.to_s))
        @dirty_tracking_suspended = false
        establish_initial_dirty_baseline
        __after_initialize
      end

      # Accept a dynamic attribute hash whose values may include association
      # records or arrays of records as well as scalar columns.
      def initialize(args : Hash(String | Symbol, T)) forall T
        @dirty_tracking_suspended = true
        __apply_scope_attributes
        set_attributes(args.transform_keys(&.to_s))
        @dirty_tracking_suspended = false
        establish_initial_dirty_baseline
        __after_initialize
      end

      # Builds a new (unsaved) record with all columns at their defaults. Assign
      # attributes afterward, then `#save`.
      #
      # ```
      # user = User.new
      # user.email = "a@example.com"
      # user.save
      # ```
      def initialize
        if Fiber.current.grant_scoping_stacks
          @dirty_tracking_suspended = true
          __apply_scope_attributes
          @dirty_tracking_suspended = false
        end
        establish_initial_dirty_baseline
        __after_initialize
      end

      # Builds a new (unsaved) record from keyword arguments and yields it
      # before `after_initialize` runs, so the block can set further attributes.
      # Values assigned in the block count as changes, like any later setter.
      #
      # ```
      # user = User.new(email: "a@example.com") { |u| u.name = "Ada" }
      # ```
      def initialize(**args, &)
        @dirty_tracking_suspended = true
        __apply_scope_attributes
        __set_named_attributes(args)
        @dirty_tracking_suspended = false
        establish_initial_dirty_baseline
        yield self
        __after_initialize
      end

      # :ditto:
      #
      # Attributes-hash form of the initializer block.
      def initialize(args : Grant::ModelArgs, &)
        @dirty_tracking_suspended = true
        __apply_scope_attributes
        set_attributes(args.transform_keys(&.to_s))
        @dirty_tracking_suspended = false
        establish_initial_dirty_baseline
        yield self
        __after_initialize
      end

      # Starts a new record from the attributes of the `scoping { }` relation
      # in effect, so `Post.where(published: true).scoping { Post.new }` is
      # published. Arguments passed to `new` are applied afterwards and win.
      private def __apply_scope_attributes : Nil
        return unless Fiber.current.grant_scoping_stacks

        attributes = Grant::Scoping.new_record_attributes(self.class)
        set_attributes(attributes) unless attributes.empty?
      end

      # Captures the values supplied to initialize as the initial baseline.
      # Later setter calls are then tracked even while the record is new.
      private def establish_initial_dirty_baseline
        @original_attributes.try &.clear
        @changed_attributes.try &.clear
        @previous_changes.try &.clear
        capture_original_attributes
      end

      private def enlist_transaction_record
        return unless Grant::Transaction.in_explicit_transaction?

        Grant::Transaction.enlist_record_rollback_action(__transaction_rollback_action)
      end

      # Captures the complete in-memory state needed to undo a transaction write.
      # The action closes over typed column values so rollback does not pass
      # custom converter values through the public attribute writer.
      private def __transaction_rollback_action : Proc(Nil)
        column_values = capture_column_values_for_transaction
        # Nothing is created just to be snapshotted: a record that never changed
        # a column has no dirty hashes, and its snapshot of them is nil.
        original_attributes = @original_attributes.try(&.dup)
        changed_attributes = @changed_attributes.try(&.dup)
        previous_changes = @previous_changes.try(&.dup)
        aggregation_changes_snapshot = @aggregation_changes.try(&.dup)
        pending_commit_callbacks = @_pending_commit_callbacks.try(&.dup)
        was_new_record = new_record?
        was_destroyed = destroyed?
        was_readonly = readonly?

        Proc(Nil).new do
          restore_column_values_for_transaction(column_values)
          @original_attributes = original_attributes.try(&.dup)
          @changed_attributes = changed_attributes.try(&.dup)
          @previous_changes = previous_changes.try(&.dup)
          @aggregation_changes = aggregation_changes_snapshot.try(&.dup)
          self.new_record = was_new_record
          restore_destroyed_state(was_destroyed)
          mark_readonly(was_readonly)
          _pending_commit_callbacks.clear
          if pending_commit_callbacks
            _pending_commit_callbacks.concat(pending_commit_callbacks)
          end
        end
      end
    end

    # Connection handling is automatic now
    before_save { self.class.mark_write_operation }
    before_destroy { self.class.mark_write_operation }
    after_save :clear_dirty_state
    
    # Dirty tracking API methods
    
    # Returns true if any attributes have been changed since the last save.
    #
    # ```
    # user = User.find!(1)
    # user.changed? # => false
    # 
    # user.name = "New Name"
    # user.changed? # => true
    # 
    # user.save
    # user.changed? # => false
    # ```
    def changed? : Bool
      has_changes_to_save?
    end
    
    # Returns a hash of all changed attributes with their original and new values.
    #
    # The hash keys are attribute names, and values are tuples of `{original_value, new_value}`.
    #
    # ```
    # user = User.find!(1)
    # user.name # => "John"
    # user.age # => 25
    # 
    # user.name = "Jane"
    # user.age = 26
    # 
    # user.changes
    # # => {"name" => {"John", "Jane"}, "age" => {25, 26}}
    # ```
    def changes
      refresh_dirty
      @changed_attributes.try(&.dup) || {} of String => Tuple(DirtyValue, DirtyValue)
    end
    
    # Returns the names of the attributes that have been changed (ActiveModel's
    # `changed`).
    #
    # ```
    # user = User.find!(1)
    # user.name = "New Name"
    # user.email = "new@example.com"
    #
    # user.changed # => ["name", "email"]
    # ```
    def changed : Array(String)
      refresh_dirty
      if pending = @changed_attributes
        pending.keys
      else
        [] of String
      end
    end

    # Returns the original value of every changed attribute, keyed by name
    # (ActiveModel's `changed_attributes`). Values are the stored (database)
    # representation, like `changes`; use `<attr>_was` for the column type.
    #
    # ```
    # user.name = "New Name"
    # user.changed_attributes # => {"name" => "Old Name"}
    # ```
    def changed_attributes : Hash(String, DirtyValue)
      attributes_in_database
    end

    # Returns the changes that were saved in the last save operation.
    #
    # This is useful for after_save callbacks to know what changed.
    #
    # ```
    # user = User.find!(1)
    # user.name = "New Name"
    # user.save
    # 
    # user.previous_changes # => {"name" => {"Old Name", "New Name"}}
    # user.changes # => {} (empty after save)
    # ```
    def previous_changes
      @previous_changes.try(&.dup) || {} of String => Tuple(DirtyValue, DirtyValue)
    end
    
    # Alias for `previous_changes`. Returns the changes from the last save.
    #
    # This method provides Rails-compatible API.
    #
    # ```
    # user.saved_changes # => {"name" => {"Old Name", "New Name"}}
    # ```
    def saved_changes
      previous_changes
    end
    
    # Returns true if the specified attribute has been changed.
    #
    # ```
    # user = User.find!(1)
    # user.name = "New Name"
    # 
    # user.attribute_changed?("name")  # => true
    # user.attribute_changed?(:name)    # => true
    # user.attribute_changed?("email") # => false
    # ```
    def attribute_changed?(name : String | Symbol) : Bool
      refresh_dirty
      if pending = @changed_attributes
        pending.has_key?(name.to_s)
      else
        false
      end
    end
    
    # Returns the original value of an attribute before it was changed.
    #
    # If the attribute hasn't changed, returns the current value.
    #
    # ```
    # user = User.find!(1)
    # user.name # => "John"
    # 
    # user.name = "Jane"
    # user.attribute_was("name") # => "John"
    # user.attribute_was(:email)  # => "john@example.com" (unchanged)
    # ```
    def attribute_was(name : String | Symbol)
      refresh_dirty
      name_str = name.to_s
      if change = @changed_attributes.try(&.[name_str]?)
        change[0]
      else
        read_attribute(name_str)
      end
    end
    
    # Returns true if the specified attribute was changed in the last save.
    #
    # Useful in after_save callbacks to check what was changed.
    #
    # ```
    # after_save :send_email_if_email_changed
    # 
    # private def send_email_if_email_changed
    #   if saved_change_to_attribute?("email")
    #     # Send confirmation email
    #   end
    # end
    # ```
    # `saved_change_to_attribute?`, `saved_change_to_attribute` and the other
    # after-save readers live in `Grant::Dirty`.

    # Returns `true` when *name* has a pending change that the next save will
    # write. Optional `from:` and `to:` filters compare against the original and
    # pending values, respectively.
    def will_save_change_to_attribute?(name : String | Symbol) : Bool
      !current_attribute_change(name).nil?
    end

    def will_save_change_to_attribute?(name : String | Symbol, *, from) : Bool
      if change = current_attribute_change(name)
        change[0] == from
      else
        false
      end
    end

    def will_save_change_to_attribute?(name : String | Symbol, *, to) : Bool
      if change = current_attribute_change(name)
        change[1] == to
      else
        false
      end
    end

    def will_save_change_to_attribute?(name : String | Symbol, *, from, to) : Bool
      if change = current_attribute_change(name)
        change[0] == from && change[1] == to
      else
        false
      end
    end

    private def current_attribute_change(name : String | Symbol)
      refresh_dirty
      @changed_attributes.try(&.[name.to_s]?)
    end
    
    # Returns the value of an attribute before the last save.
    #
    # If the attribute wasn't changed in the last save, returns current value.
    #
    # ```
    # user = User.find!(1)
    # user.name # => "John"
    # 
    # user.name = "Jane"
    # user.save
    # 
    # user.attribute_before_last_save("name") # => "John"
    # user.name = "Jim"
    # user.attribute_before_last_save("name") # => "John" (still from last save)
    # ```
    def attribute_before_last_save(name : String | Symbol)
      name_str = name.to_s
      if change = @previous_changes.try(&.[name_str]?)
        change[0]
      else
        read_attribute(name_str)
      end
    end
    
    # Restores attributes to their original values.
    #
    # If specific attributes are provided, only those are restored.
    # If no attributes are provided, all changed attributes are restored.
    #
    # ```
    # user = User.find!(1)
    # original_name = user.name # => "John"
    # original_age = user.age   # => 25
    # 
    # user.name = "Jane"
    # user.age = 26
    # 
    # # Restore only name
    # user.restore_attributes(["name"])
    # user.name # => "John"
    # user.age  # => 26
    # 
    # # Restore all changes
    # user.restore_attributes
    # user.age # => 25
    # ```
    def restore_attributes(attributes : Array(String)? = nil)
      refresh_dirty
      ensure_dirty_tracking_initialized
      attrs = attributes || dirty_tracking_hashes[1].keys
      
      # Temporarily store changed attributes to restore
      changes_to_restore = {} of String => {Grant::Columns::Type, Grant::Columns::Type}
      attrs.each do |attr|
        if change = dirty_tracking_hashes[1][attr]?
          changes_to_restore[attr] = change
        end
      end
      
      # Clear the changes for the attributes being restored
      attrs.each do |attr|
        dirty_tracking_hashes[1].delete(attr)
        @forced_changes.try &.delete(attr)
      end
      
      # Restore the values using write_attribute; a snapshot is written so the
      # restored column never aliases the stored baseline.
      changes_to_restore.each do |attr, change|
        write_attribute(attr, snapshot_dirty_value(change[0]))
        # Remove the change that write_attribute just added
        dirty_tracking_hashes[1].delete(attr)
      end
    end
    
    # Clear dirty state after save
    private def clear_dirty_state
      refresh_dirty
      pending = @changed_attributes
      if pending && !pending.empty?
        @previous_changes = pending.dup
        pending.clear
      else
        @previous_changes.try(&.clear)
      end
      clear_assigned_attributes
      @forced_changes.try &.clear
      @original_attributes.try &.clear
      @new_record = false

      # Capture current state as new originals
      capture_original_attributes
    end

    # Clears pending changes for columns written by a callback-free persistence
    # helper, without disturbing other unsaved changes or previous_changes.
    private def clear_dirty_tracking_for(attribute_names : Array(String))
      ensure_dirty_tracking_initialized
      attribute_names.each do |attribute_name|
        dirty_tracking_hashes[1].delete(attribute_name)
        @forced_changes.try &.delete(attribute_name)
        # A watched column keeps a copy, so a later in-place edit of the live
        # value is still detected.
        dirty_tracking_hashes[0][attribute_name] = baseline_dirty_value(attribute_name, read_attribute(attribute_name).as(DirtyValue))
      end
    end
    
    # This will be overridden in each model to capture all column values
    protected def capture_original_attributes
      capture_mutation_baselines
    end
  end
end
