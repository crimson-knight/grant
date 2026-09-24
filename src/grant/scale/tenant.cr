module Grant
  # Raised when a `multitenant` model is queried but no current tenant is set.
  #
  # This is a guard rail against accidental cross-tenant full-table scans on a
  # large shared table — the billion-row footgun. Wrap queries in
  # `Grant::Tenant.with(id) { ... }`, or use `Model.unscoped { ... }` for
  # deliberate cross-tenant access.
  class NoTenantError < Grant::ErrorBase
  end

  # Raised when a record or bulk insert attempts to write another tenant's row.
  class TenantMismatchError < Grant::ErrorBase
  end

  # Fiber-local current-tenant context for `multitenant` models.
  #
  # Mirrors `Grant::ShardManager`'s fiber-local pattern: the current tenant is
  # stored per-`Fiber`, so concurrent requests on different fibers never leak a
  # tenant across each other.
  #
  # ```
  # Grant::Tenant.with(tenant_id) do
  #   Todo.where(done: false).find_each { |t| ... } # auto WHERE tenant_id = ?
  # end
  # ```
  class Tenant
    @@current = {} of Fiber => Grant::Columns::Type
    @@mutex = Mutex.new

    # Runs *block* with *id* as the current tenant for this fiber, restoring the
    # previous tenant (or clearing it) afterward.
    def self.with(id : Grant::Columns::Type, &block : -> T) : T forall T
      fiber = Fiber.current
      had_previous = false
      previous = nil.as(Grant::Columns::Type)
      @@mutex.synchronize do
        had_previous = @@current.has_key?(fiber)
        previous = @@current[fiber]?
        @@current[fiber] = id
      end

      begin
        yield
      ensure
        @@mutex.synchronize do
          if had_previous
            @@current[fiber] = previous
          else
            # Drop the entry entirely so long-lived fibers don't accumulate
            # dead tenant context.
            @@current.delete(fiber)
          end
        end
      end
    end

    # The current tenant for this fiber, or nil if none is set.
    def self.current : Grant::Columns::Type
      @@mutex.synchronize { @@current[Fiber.current]? }
    end

    # The current tenant for this fiber, raising `NoTenantError` if unset.
    # Used by the `multitenant` default scope to fail loudly rather than scan
    # the whole table.
    def self.current! : Grant::Columns::Type
      value = current
      if value.nil?
        raise Grant::NoTenantError.new(
          "No current tenant set. Wrap the query in Grant::Tenant.with(id) { ... }, " \
          "or use Model.unscoped { ... } for deliberate cross-tenant access.")
      end
      value
    end

    # True when a tenant is set for this fiber.
    def self.set? : Bool
      !current.nil?
    end

    # Clears the current tenant for this fiber (mainly for tests).
    def self.clear : Nil
      @@mutex.synchronize { @@current.delete(Fiber.current) }
    end
  end
end

module Grant::Scale::MultiTenancy
  # Declares a model as multi-tenant, scoped by *column*.
  #
  # Installs a `default_scope` that filters every query by
  # `Grant::Tenant.current!` on *column*, raising `Grant::NoTenantError` when no
  # tenant is set (preventing accidental cross-tenant scans of a large shared
  # table). `Model.unscoped { ... }` still bypasses the scope for admin /
  # cross-tenant work — use it deliberately.
  #
  # ```
  # class Todo < Grant::Base
  #   column id : Int64, primary: true
  #   column tenant_id : Int64
  #   column done : Bool = false
  #   multitenant :tenant_id
  # end
  #
  # Grant::Tenant.with(tenant_id) do
  #   Todo.where(done: false).select # => WHERE tenant_id = ? AND done = ?
  # end
  #
  # New records with a nil tenant column inherit the current tenant. An
  # explicitly different value raises `Grant::TenantMismatchError` when saved,
  # unless the write is inside `Todo.unscoped { ... }`.
  # ```
  macro multitenant(column)
    # Records the tenant column for diagnostics / introspection.
    class_getter multitenant_column : String = {{ column.id.stringify }}

    # :nodoc:
    def self.__multitenant? : Bool
      true
    end

    default_scope { where({{ column.id.stringify }}, :eq, Grant::Tenant.current!) }

    # Keep instance writes tenant-bound even when a record came from an
    # unscoped query. Only the tenant predicate is used here so unrelated
    # default scopes do not block updates to already-loaded records.
    # :nodoc:
    def self.__tenant_write_scope : Grant::Query::Builder(self)
      if _unscoped?
        unscoped
      else
        unscoped.where(multitenant_column, :eq, Grant::Tenant.current!)
      end
    end

    # :nodoc:
    def self.__apply_tenant_to_bulk_attributes(attributes : Array(Hash(String | Symbol, Grant::Columns::Type)))
      return attributes if _unscoped?

      current_tenant = Grant::Tenant.current!
      attributes.each do |attribute_values|
        tenant_key = attribute_values.keys.find { |key| key.to_s == multitenant_column }
        if key = tenant_key
          value = attribute_values[key]?
          if value.nil?
            attribute_values[key] = current_tenant
          elsif value != current_tenant
            raise Grant::TenantMismatchError.new(
              "Cannot write #{multitenant_column}=#{value} while current tenant is #{current_tenant}. " \
              "Use #{self.name}.unscoped { ... } for deliberate cross-tenant writes.")
          end
        else
          attribute_values[multitenant_column] = current_tenant
        end
      end
      attributes
    end

    after_initialize :__assign_current_tenant_if_missing
    before_save :__ensure_current_tenant!
    before_destroy :__ensure_current_tenant!

    private def __assign_current_tenant_if_missing
      return if self.class._unscoped?
      return unless read_attribute({{ column.id.stringify }}).nil?

      if current_tenant = Grant::Tenant.current
        write_attribute({{ column.id.stringify }}, current_tenant)
      end
    end

    private def __ensure_current_tenant!
      return if self.class._unscoped?

      current_tenant = Grant::Tenant.current!
      tenant_value = read_attribute({{ column.id.stringify }})
      if new_record? && tenant_value.nil?
        write_attribute({{ column.id.stringify }}, current_tenant)
        tenant_value = current_tenant
      end

      unless tenant_value == current_tenant
        raise Grant::TenantMismatchError.new(
          "Cannot save or destroy #{self.class.name} with #{self.class.multitenant_column}=#{tenant_value} " \
          "while current tenant is #{current_tenant}. Use #{self.class.name}.unscoped { ... } " \
          "for deliberate cross-tenant writes.")
      end
    end
  end
end
