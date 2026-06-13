# Single Table Inheritance (STI) for Grant.
#
# STI lets an entire class hierarchy share a single database table. A
# discriminator column (by default `type`) records which concrete class each
# row belongs to, so that loading a row instantiates the correct subclass.
#
# Enable STI on the *root* of the hierarchy by including `Grant::STI` and
# declaring the inheritance column:
#
# ```
# class Persona < Grant::Base
#   include Grant::STI
#
#   column id : Int64, primary: true
#   column type : String # the STI discriminator
#   column name : String
# end
#
# class AdminPersona < Persona
#   column access_level : Int32?
# end
#
# class MemberPersona < Persona
#   column membership_tier : String?
# end
# ```
#
# Subclasses inherit STI behaviour automatically — they do not include the
# module again. See `docs/single_table_inheritance.md` for the full guide.
#
# ## Design notes
#
# * **Root vs. subclass detection is real and compile-time.** `sti_root`
#   walks `{{@type.superclass}}` to the class that directly enabled STI;
#   `sti_subclass?` is simply `self != sti_root`. There is no runtime stub.
# * **`table_name` is inherited** by overriding it in every descendant to
#   delegate to its superclass, recursing to the root's table.
# * **Subclass queries filter by type including descendants** using a
#   compile-time descendant set drawn from the STI registry.
# * **Immutable type** is enforced with an explicit `@_sti_type_mutable`
#   flag — never `caller`/backtrace inspection.
module Grant::STI
  # Compile-time registry of every class that participates in STI, keyed by
  # its `sti_name` (the class name). Mirrors `Grant::Polymorphic`'s registry.
  REGISTERED_TYPES = {} of String => ASTNode

  # Registers an STI class for type resolution at compile time.
  macro register_sti_type(name, klass)
    {% Grant::STI::REGISTERED_TYPES[name] = klass %}
  end

  # Raised when a `type` value in the database does not map to a registered
  # STI subclass.
  class SubclassNotFound < Exception; end

  # Raised when code attempts to write the inheritance column directly on a
  # persisted record. Use `becomes!` to change a record's type.
  class ImmutableTypeError < Exception; end

  # Raised when an STI type cast / conversion fails.
  class TypeCastingError < Exception; end

  # Hook invoked when a root model does `include Grant::STI`.
  #
  # The root gets the STI class methods and instance methods, and — crucially —
  # an `inherited` macro that fires for *every* descendant so that subclasses
  # pick up the type-column delegation, table-name delegation, and registry
  # registration without re-including the module.
  macro included
    # Register the root itself in the STI registry.
    Grant::STI.register_sti_type({{@type.name.stringify}}, {{@type}})

    extend Grant::STI::ClassMethods
    include Grant::STI::InstanceMethods

    # Guard direct writes to the inheritance column on persisted records.
    # Defined ONCE on the root and inherited; `super` reaches the per-class
    # `Grant::Columns#write_attribute` (which correctly writes subclass-only
    # columns too — verified). New records may set the type (the auto-set
    # callback does), loads and `becomes` flip the mutability flag.
    def write_attribute(attribute_name : String | Symbol, value : Grant::Columns::Type)
      if attribute_name.to_s == self.class.inheritance_column
        unless new_record? || _sti_type_mutable?
          current = read_attribute(self.class.inheritance_column)
          raise Grant::STI::ImmutableTypeError.new(
            "Cannot change the inheritance column '#{attribute_name}' from " \
            "'#{current}' to '#{value}' on a persisted #{self.class.name}. " \
            "Use #becomes! to change a record's STI type."
          )
        end
      end
      super(attribute_name, value)
    end

    # Register the auto-set callback on the root (and again per subclass below,
    # since each class keeps its own CALLBACKS table).
    Grant::STI.register_type_callback

    # Mark this concrete class as the STI root for the hierarchy.
    def self.sti_root_class? : Bool
      true
    end

    # Base-class (root) queries apply NO type filter — they return the whole
    # hierarchy. They select the root's own columns; rows are dispatched to the
    # correct concrete subclass by `from_rs` below.
    def self.current_scope
      __sti_unfiltered_scope
    end

    # Polymorphic loader for base-class queries.
    #
    # The row carries only the root's columns (the columns shared by every
    # member of the hierarchy). We read them with the standard sequential
    # reader into a fresh root instance, inspect the inheritance column, and —
    # when it names a subclass — re-home the already-read attributes onto a
    # correctly-typed subclass instance via `becomes`. Subclass-only columns
    # are not part of a base-class SELECT and therefore remain nil on the
    # returned instance (see the documented limitation in the STI guide).
    #
    # Defined on the root only; subclasses get the standard reader (see the
    # `inherited` hook), so subclass queries hydrate every column.
    def self.from_rs(result : ::DB::ResultSet) : self
      base = allocate_root_instance
      base.new_record = false
      base.from_rs result
      base.after_find if base.responds_to?(:after_find)

      type_col = inheritance_column
      type_value = base.read_attribute(type_col)
      if type_value.nil? || type_value.to_s == sti_name
        return base
      end

      klass = find_sti_class(type_value.to_s)
      Grant::STI.rehome_to_subclass(base, klass).as(self)
    end

    # :nodoc: allocate a plain root instance (the root itself is concrete).
    protected def self.allocate_root_instance : self
      new
    end

    macro inherited
      # Register every descendant for runtime type resolution. NOTE the escaped
      # interpolation below: this is a `macro inherited` nested inside `macro
      # included`, so an unescaped @type would resolve to the ROOT at
      # included-expansion time (registering the root repeatedly). Escaping
      # defers resolution to each subclass's own expansion.
      Grant::STI.register_sti_type(\{{@type.name.stringify}}, \{{@type}})

      # Annotations do not inherit in Crystal, so a subclass would otherwise
      # compute its own table name from its class name. Delegate to the
      # superclass instead, which recurses up to the STI root's table.
      def self.table_name : String
        \{{@type.superclass}}.table_name
      end

      # Register the auto-set callback in this subclass's own CALLBACKS table.
      # (The immutable-type `write_attribute` guard is inherited from the root.)
      #
      # This runs inside `macro finished` because Grant's `Grant::Callbacks`
      # re-initializes the per-class `CALLBACKS` store in ITS OWN `macro
      # inherited`, which (for a subclass) may execute after this STI
      # `inherited` block. Registering in `finished` guarantees the callback is
      # appended after the callback store exists, so it is not wiped.
      macro finished
        Grant::STI.register_type_callback
      end

      # Subclasses are NOT the root.
      def self.sti_root_class? : Bool
        false
      end

      # Subclass reader. Reads the row with this subclass's own sequential
      # reader (its fields include all inherited columns, so this is complete
      # for rows of exactly this type). When the row's type column names a
      # *descendant* of this subclass (e.g. `AdminPersona.all` returning a
      # `SuperAdminPersona` row), the already-read shared attributes are
      # re-homed onto the descendant so the instance is correctly typed.
      # Descendant-only columns are not in this subclass's SELECT, so they stay
      # nil (the documented base-query limitation, applied at each level).
      def self.from_rs(result : ::DB::ResultSet) : self
        model = new
        model.new_record = false
        model.from_rs result
        model.after_find if model.responds_to?(:after_find)

        type_value = model.read_attribute(inheritance_column)
        if type_value.nil? || type_value.to_s == sti_name
          return model
        end

        klass = find_sti_class(type_value.to_s)
        # Only re-home to a *descendant* of this class. A row of an unrelated
        # type can only appear here via `unscoped` (which drops the type
        # filter); such a row is returned typed as the queried class with its
        # shared columns, since the result collection is `Array(self)`.
        if klass <= self
          Grant::STI.rehome_to_subclass(model, klass).as(self)
        else
          model
        end
      end

      # Scope every query for this subclass to its own type plus any
      # registered descendants (AR semantics). We build the unfiltered base
      # scope directly (NOT via `super`, which would reach the root's
      # column-expanding `current_scope`), preserving default scopes and the
      # chosen DB adapter, then AND-in the type filter. The root class is
      # intentionally left unscoped (returns mixed types).
      def self.current_scope
        query = __sti_unfiltered_scope
        names = sti_names_for_query
        if names.size == 1
          query.where(inheritance_column, :eq, names.first)
        else
          # `names` is an Array(String) — a member of Grant::Columns::Type's
          # SupportedArrayTypes — which the builder expands into an IN clause.
          query.where(inheritance_column, :in, names)
        end
        query
      end
    end
  end

  # Registers the before-save callback that auto-sets the inheritance column on
  # new records. Invoked once per STI class so the callback lands in that
  # class's own CALLBACKS table (callbacks do not merge across the hierarchy in
  # Grant's model).
  #
  # NOTE: the `@_sti_type_mutable` ivar and accessors, plus the `write_attribute`
  # immutability guard, are defined ONCE on the root (and inherited) — see the
  # `included` hook. Re-declaring an annotated ivar in a subclass is a compile
  # error, and the guard works correctly through inheritance via `super`.
  macro register_type_callback
    before_save :__sti_ensure_type_column
  end

  module ClassMethods
    # Returns the name of the discriminator (type) column as a `String`,
    # defaulting to `"type"`.
    #
    # Override this method (or set it via the `sti` macro) to use a custom
    # column such as `"persona_type"`. Whatever it returns is the column Grant
    # reads to decide which subclass to instantiate, and writes when persisting a
    # new record.
    #
    # ```
    # Persona.inheritance_column      # => "type"
    # AdminPersona.inheritance_column # => "type" (inherited)
    # ```
    def inheritance_column : String
      "type"
    end

    # Returns the value stored in the inheritance column for this class as a
    # `String`, defaulting to the class name.
    #
    # This is the literal string written to the `inheritance_column` for records
    # of this class, and the value a query filters on for this subclass.
    #
    # ```
    # AdminPersona.sti_name # => "AdminPersona"
    # ```
    def sti_name : String
      name
    end

    # Returns the STI root class for this class — the ancestor that did
    # `include Grant::STI`.
    #
    # The root's direct superclass is `Grant::Base` (that is where STI was
    # enabled), so the root returns `self`; every deeper subclass delegates to
    # its superclass, recursing up to the root. This is real, compile-time
    # superclass walking — not a stub. (Return type is the root model class, not
    # annotated because each call site resolves to a different concrete class.)
    #
    # ```
    # AdminPersona.sti_root # => Persona
    # Persona.sti_root      # => Persona
    # ```
    def sti_root
      {% if @type.superclass.id == "Grant::Base" %}
        self
      {% else %}
        {{@type.superclass}}.sti_root
      {% end %}
    end

    # Returns `true` when this class is an STI subclass (i.e. not the root),
    # `false` for the root itself.
    #
    # ```
    # Persona.sti_subclass?      # => false (the root)
    # AdminPersona.sti_subclass? # => true
    # ```
    def sti_subclass? : Bool
      self != sti_root
    end

    # Returns the base (root) class of the STI hierarchy — an alias for
    # `#sti_root`, provided for ActiveRecord familiarity.
    #
    # ```
    # MemberPersona.base_class # => Persona
    # ```
    def base_class
      sti_root
    end

    # Resolves a `type` column value (*type_name*) to its registered subclass and
    # returns that class. Raises `Grant::STI::SubclassNotFound` when no class is
    # registered for the value (e.g. the class is not yet required).
    #
    # Used internally by the polymorphic loaders, but also handy when you have a
    # raw type string and want the matching class. (Return type is a
    # `Grant::Base.class`; not annotated because the concrete subclass varies.)
    #
    # ```
    # Persona.find_sti_class("AdminPersona") # => AdminPersona
    # Persona.find_sti_class("Nope")         # raises Grant::STI::SubclassNotFound
    # ```
    def find_sti_class(type_name : String)
      klass = Grant::STI.find_sti_class_by_name(type_name)
      if klass.nil?
        raise Grant::STI::SubclassNotFound.new(
          "Single Table Inheritance failed to locate subclass '#{type_name}'. " \
          "Ensure the class is defined and required."
        )
      end
      klass
    end

    # Returns the `Array(String)` of `sti_name`s a query for this class should
    # match: this class itself plus all of its registered descendants (matching
    # ActiveRecord semantics). Computed at compile time from the full STI
    # registry via the resolver generated in `macro finished`.
    #
    # This is why `Persona.all` returns admins and members too, while
    # `AdminPersona.all` is restricted to admins (and any admin subclasses).
    #
    # ```
    # Persona.sti_names_for_query      # => ["Persona", "AdminPersona", "MemberPersona"]
    # AdminPersona.sti_names_for_query # => ["AdminPersona"]
    # ```
    def sti_names_for_query : Array(String)
      Grant::STI.descendant_names(self.name)
    end

    # Builds an unfiltered `Grant::Query::Builder` for this class, applying any
    # default scope but NOT the STI type filter. Mirrors
    # `Grant::Scoping::ClassMethods#current_scope` so STI can compose without
    # relying on the `super` chain (which the root re-points for column
    # expansion). Internal building block for `current_scope`; not part of the
    # public query API.
    def __sti_unfiltered_scope
      db_type = case adapter.class.to_s
                when "Grant::Adapter::Pg"
                  Grant::Query::Builder::DbType::Pg
                when "Grant::Adapter::Mysql"
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end

      query = Grant::Query::Builder(self).new(db_type)

      if !_unscoped? && self.responds_to?(:_has_default_scope?) && self.responds_to?(:apply_default_scope) && self._has_default_scope?
        query = self.apply_default_scope(query)
      end

      query
    end
  end

  module InstanceMethods
    # Explicit, opt-in mutability flag for the inheritance column. Default
    # false; flipped true only during DB load and `becomes`. No backtrace
    # inspection — see design notes. Declared once here and inherited.
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_sti_type_mutable : Bool = false

    # :nodoc:
    def _sti_type_mutable=(value : Bool)
      @_sti_type_mutable = value
    end

    # :nodoc:
    def _sti_type_mutable? : Bool
      @_sti_type_mutable
    end

    # Auto-set the inheritance column on new records.
    private def __sti_ensure_type_column
      return unless new_record?
      col = self.class.inheritance_column
      if read_attribute(col).nil?
        write_attribute(col, self.class.sti_name)
      end
    end

    # After a polymorphic base-class load, snapshot the current attribute
    # values as the dirty-tracking baseline (the standard `from_rs` does this
    # for sequential loads; the polymorphic path must do it explicitly).
    def __sti_capture_loaded_state
      ensure_dirty_tracking_initialized
      @changed_attributes.not_nil!.clear
      capture_original_attributes
    end

    # Converts this record to another class in the same STI hierarchy,
    # in memory only. All attributes (including nil/false), dirty-tracking
    # state, `new_record`/`destroyed` flags, and the primary key are copied
    # faithfully. The returned instance carries the target class's type value.
    def becomes(klass : T.class) : T forall T
      became = klass.new
      __sti_copy_state_to(became)
      # Stamp the new type, bypassing the immutability guard.
      became._sti_type_mutable = true
      became.write_attribute(klass.inheritance_column, klass.sti_name)
      became._sti_type_mutable = false
      became
    end

    # Like `becomes`, but also persists the new type to the database via a
    # parameterized UPDATE (no string interpolation of values). The receiver's
    # own type column is updated in memory too.
    def becomes!(klass : T.class) : T forall T
      became = becomes(klass)

      unless new_record?
        col = klass.inheritance_column
        pk_name = self.class.primary_name
        sql = "UPDATE #{self.class.quoted_table_name} SET #{self.class.quote(col)} = ? WHERE #{self.class.quote(pk_name)} = ?"
        sql = self.class.adapter.ensure_clause_template(sql)
        params = [klass.sti_name.as(Grant::Columns::Type), primary_key_value.as(Grant::Columns::Type)]

        self.class.mark_write_operation
        self.class.adapter.open do |db|
          db.exec(sql, args: params)
        end

        # Reflect the persisted change on the receiver as well.
        @_sti_type_mutable = true
        write_attribute(col, klass.sti_name)
        @_sti_type_mutable = false
      end

      became
    end

    # Copies all column attributes (preserving nil and false), dirty-tracking
    # state, and lifecycle flags from `self` to `target`.
    protected def __sti_copy_state_to(target)
      # Allow the type column to be written during the copy.
      target._sti_type_mutable = true

      self.class.fields.each do |field_name|
        next unless target.class.fields.includes?(field_name)
        value = read_attribute(field_name)
        # Faithful copy: write every value, including nil and false.
        target.write_attribute(field_name, value)
      end

      target._sti_type_mutable = false

      # Lifecycle flags.
      target.new_record = new_record?
      target.__sti_set_destroyed(destroyed?)

      # Dirty-tracking state. `__sti_copy_dirty_from` initializes the target's
      # tracking hashes itself.
      ensure_dirty_tracking_initialized
      target.__sti_copy_dirty_from(@original_attributes, @changed_attributes, @previous_changes)
    end

    # :nodoc: setter for the destroyed flag (no public setter exists).
    def __sti_set_destroyed(value : Bool)
      @destroyed = value
    end

    # :nodoc: replaces this instance's dirty-tracking state with copies of the
    # provided hashes. Crystal has no `instance_variable_set`, so STI uses this
    # explicit helper to transplant state during `becomes`.
    def __sti_copy_dirty_from(
      original : Hash(String, Grant::Base::DirtyValue)?,
      changed : Hash(String, Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue))?,
      previous : Hash(String, Tuple(Grant::Base::DirtyValue, Grant::Base::DirtyValue))?,
    )
      ensure_dirty_tracking_initialized
      @original_attributes = original.dup if original
      @changed_attributes = changed.dup if changed
      @previous_changes = previous.dup if previous
    end
  end

  # Generated after all types are known: the runtime type-name → class resolver
  # used by base-class polymorphic loading and `find_sti_class`.
  macro finished
    # Resolves a registered STI `type` value to its class, or nil if unknown.
    def self.find_sti_class_by_name(type_name : String) : Grant::Base.class | Nil
      case type_name
      {% for name, klass in REGISTERED_TYPES %}
      when {{name}}
        {% if name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
          nil
        {% else %}
          {{klass}}
        {% end %}
      {% end %}
      else
        nil
      end
    end

    # True when `type_name` maps to a registered, non-spec STI class.
    def self.registered_sti_type?(type_name : String) : Bool
      !find_sti_class_by_name(type_name).nil?
    end

    # Returns the `sti_name`s a query for the class named *class_name* should
    # match: the class itself plus every registered descendant. The descendant
    # relationships are resolved at compile time from the complete registry.
    def self.descendant_names(class_name : String) : Array(String)
      case class_name
      {% for outer_name, outer_klass in REGISTERED_TYPES %}
      when {{outer_name}}
        {% descendants = [] of StringLiteral %}
        {% for inner_name, inner_klass in REGISTERED_TYPES %}
          {% if inner_klass.resolve <= outer_klass.resolve %}
            {% descendants << inner_name %}
          {% end %}
        {% end %}
        {{descendants}} of String
      {% end %}
      else
        [class_name]
      end
    end

    # Re-homes an already-loaded base (root) instance onto a correctly-typed
    # subclass instance, preserving the loaded (persisted, non-dirty) state.
    #
    # Used by base-class queries: the root reads the row's shared columns into
    # a root instance, then this transplants those attributes onto the right
    # subclass so callers get `record.is_a?(AdminPersona)`. Subclass-only
    # columns are not present in a base-class SELECT, so they stay nil.
    def self.rehome_to_subclass(base : Grant::Base, klass : Grant::Base.class) : Grant::Base
      case klass.name
      {% for name, kl in REGISTERED_TYPES %}
      {% unless name.starts_with?("Validators::") || name.starts_with?("Spec::") %}
      when {{name}}
        instance = {{kl}}.new
        instance.new_record = false
        instance._sti_type_mutable = true
        # Copy every field the subclass shares with the loaded base instance,
        # preserving nil and false.
        {{kl}}.fields.each do |f|
          if base.class.fields.includes?(f)
            instance.write_attribute(f, base.read_attribute(f))
          end
        end
        instance._sti_type_mutable = false
        instance.__sti_capture_loaded_state
        instance.after_find if instance.responds_to?(:after_find)
        instance
      {% end %}
      {% end %}
      else
        raise Grant::STI::SubclassNotFound.new("Cannot build unregistered STI class #{klass.name}")
      end
    end
  end
end
