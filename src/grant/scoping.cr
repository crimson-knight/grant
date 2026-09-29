# Named scopes and default scopes for Grant models.
#
# A **named scope** (`scope`) defines a reusable class method that returns a
# `Grant::Query::Builder` you can chain further. A **default scope**
# (`default_scope`) is applied automatically to every query on the model until
# you opt out with `unscoped`. The class-level query entry points (`all`,
# `where`, `order`, `find`, ...) all route through `current_scope`, so the
# default scope is transparently included.
#
# ```
# class Post < Grant::Base
#   connection sqlite
#   column id : Int64, primary: true
#   column title : String
#   column published : Bool = false
#   column deleted_at : Time?
#
#   # Named scopes: each takes the running query and returns a refined one.
#   scope :published, ->(q : Grant::Query::Builder(Post)) { q.where(published: true) }
#   scope :recent, ->(q : Grant::Query::Builder(Post)) { q.order(created_at: :desc) }
#
#   # Default scope: soft-deleted rows are hidden unless you go `unscoped`.
#   default_scope { where(deleted_at: nil) }
# end
#
# Post.published.all        # WHERE deleted_at IS NULL AND published = true
# Post.published.recent.all # the same, ordered by created_at DESC
# Post.unscoped.all         # ALL rows, including soft-deleted ones
# ```
#
# ## Multi-tenancy pattern
#
# A `default_scope` that reads fiber-local context is how Grant implements
# tenant isolation — see `Grant::Scale::MultiTenancy#multitenant`, which expands
# to roughly:
#
# ```
# class Todo < Grant::Base
#   column tenant_id : Int64
#   # every query is filtered to the current tenant; raises if none is set
#   default_scope { where("tenant_id", :eq, Grant::Tenant.current!) }
# end
#
# Grant::Tenant.with(tenant_id) do
#   Todo.all # => WHERE tenant_id = <tenant_id>
# end
# Todo.unscoped { |q| q.select } # deliberate cross-tenant access
# ```
module Grant::Scoping
  @@unscoped_fibers = {} of {Fiber, String} => Int32
  @@unscoped_mutex = Mutex.new

  # Tracks unscoped blocks per model and fiber so one request cannot disable
  # another request's default scope.
  def self.unscoped?(model_name : String) : Bool
    @@unscoped_mutex.synchronize do
      @@unscoped_fibers[{Fiber.current, model_name}]? == 1
    end
  end

  def self.set_unscoped(model_name : String, value : Bool) : Nil
    @@unscoped_mutex.synchronize do
      key = {Fiber.current, model_name}
      if value
        @@unscoped_fibers[key] = 1
      else
        @@unscoped_fibers.delete(key)
      end
    end
  end

  macro included
    macro inherited
      def self._unscoped? : Bool
        Grant::Scoping.unscoped?(self.name)
      end

      def self._unscoped=(value : Bool)
        Grant::Scoping.set_unscoped(self.name, value)
      end
    end
  end

  # Defines a named scope — a reusable class method *name* that applies *body*
  # on top of the model's `current_scope` (so the default scope, if any, is
  # included). The lambda may take the current `Grant::Query::Builder` as its
  # first argument, or use class-level query methods such as `where`, which also
  # start from `current_scope`. Any remaining lambda arguments are scope inputs.
  # Returns a model-specific relation with the model's named scopes available
  # for further chaining, or terminate it with `all`/`first`/etc.
  #
  # ```
  # class Post < Grant::Base
  #   scope :published, ->(q : Grant::Query::Builder(Post)) { q.where(published: true) }
  # end
  #
  # Post.published            # => Post::BuildNamedScopeRelation
  # Post.published.recent.all # => Array(Post), filtered and ordered
  # Post.published.count      # chain any query-builder method
  # ```
  macro scope(name, body)
    # Each model gets a relation subtype so calls like `Post.published.recent`
    # can resolve all of that model's scope methods at compile time.
    class BuildNamedScopeRelation < Grant::Query::Builder({{@type}})
      # Relation methods return copies, and a copy keeps this subtype, so the
      # result of a scope body is normally already the relation to hand back.
      # A body that returns some other builder is converted, keeping its clauses.
      def self.adopt(result : Grant::Query::Builder({{@type}})) : BuildNamedScopeRelation
        return result if result.is_a?(BuildNamedScopeRelation)

        relation = new(result.db_type, result.boolean_operator)
        result.copy_state_to(relation)
        relation
      end

      def {{name.id}}(*args) : BuildNamedScopeRelation
        {% if body.args.size > 0 && body.args.first.restriction.stringify.includes?("Grant::Query::Builder") %}
          BuildNamedScopeRelation.adopt(({{body}}).call(self, *args))
        {% else %}
          BuildNamedScopeRelation.adopt(chain_copy.merge_builder(({{body}}).call(*args)))
        {% end %}
      end
    end

    # Define on the model class
    def self.{{name.id}}(*args)
      current_query = current_scope
      query = BuildNamedScopeRelation.new(current_query.db_type, current_query.boolean_operator)
      current_query.copy_state_to(query)
      {% if body.args.size > 0 && body.args.first.restriction.stringify.includes?("Grant::Query::Builder") %}
        BuildNamedScopeRelation.adopt(({{body}}).call(query, *args))
      {% else %}
        BuildNamedScopeRelation.adopt(query.merge_builder(({{body}}).call(*args)))
      {% end %}
    end
  end

  # Declares the column(s) that order an unordered relation for `first`,
  # `last`, the ordinal finders (`second`, `third`, ...) and `find_each`,
  # ahead of the primary key. Without it those use the primary key alone.
  # Plain `all`/`where` relations stay unordered.
  #
  # ```
  # class Event < Grant::Base
  #   column id : Int64, primary: true
  #   column created_at : Time
  #   implicit_order_column :created_at
  # end
  #
  # Event.first # ORDER BY created_at ASC, id ASC LIMIT 1
  # Event.last  # ORDER BY created_at DESC, id DESC LIMIT 1
  # ```
  macro implicit_order_column(*columns)
    def self.implicit_order_columns : Array(String)
      [{% for column in columns %}{{column.id.stringify}}, {% end %}] of String
    end
  end

  # Defines a default scope applied to **every** query on this model — `all`,
  # `where`, `find`, named scopes, etc. — until `unscoped` is used. *block* runs
  # in the context of a fresh `Grant::Query::Builder` for this model (so you call
  # `where`, `order`, ... directly). Declaring it sets `_has_default_scope?` to
  # true and defines `apply_default_scope`, which each concrete model's
  # generated `current_scope` invokes.
  #
  # Prefer it for invariants that should hold for almost all reads (soft-delete
  # hiding, tenant isolation). For anything you need to vary per-query, use a
  # named `scope` instead.
  #
  # ```
  # class Post < Grant::Base
  #   column deleted_at : Time?
  #   default_scope { where(deleted_at: nil) } # hide soft-deleted rows
  # end
  #
  # Post.all          # WHERE deleted_at IS NULL
  # Post.unscoped.all # all rows, scope bypassed
  # ```
  macro default_scope(&block)
    class_getter? _has_default_scope : Bool = true

    def self.apply_default_scope(query : Grant::Query::Builder(Model)) forall Model
      query.{{block.body}}
    end
  end

  # :nodoc:
  def __ensure_current_tenant! : Nil
  end

  # Defines a `QueryExtension` subclass of this model's `Grant::Query::Builder`
  # carrying the custom methods in *block*, and a `.extending` class method that
  # returns a fresh instance of it. Use it to add bespoke, chainable query
  # helpers beyond what named scopes express.
  macro extending(&block)
    class QueryExtension < Grant::Query::Builder(\{{@type}})
      {{block.body}}
    end

    def self.extending
      QueryExtension.new(adapter.database_type)
    end
  end

  module ClassMethods
    def _has_default_scope? : Bool
      false
    end

    def apply_default_scope(query : Grant::Query::Builder(Model)) forall Model
      query
    end

    # :nodoc:
    def __sti_model? : Bool
      false
    end

    def sti_root_class? : Bool
      true
    end

    def sti_names_for_query : Array(String)
      [] of String
    end

    def inheritance_column : String
      "type"
    end

    # :nodoc:
    def __multitenant? : Bool
      false
    end

    # :nodoc:
    def __tenant_write_scope : Grant::Query::Builder(self)
      unscoped
    end

    # :nodoc:
    def __apply_tenant_to_bulk_attributes(attributes : Array(Hash(String | Symbol, Grant::Columns::Type)))
      attributes
    end

    # The column an upsert must match before it may update an existing row, so
    # a conflicting row that belongs to another tenant is left alone. Nil for
    # models without tenancy.
    # :nodoc:
    def __bulk_tenant_guard_column : String?
      nil
    end

    # Fallback for Grant::Base itself. Concrete model classes generate their
    # own version in Grant::Base's inherited hook so default scopes and STI
    # filters use a builder specialized for that model.
    def current_scope : Grant::Query::Builder(self)
      db_type = if adapter.postgres?
                  Grant::Query::Builder::DbType::Pg
                elsif adapter.mysql?
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end

      # Always use the standard QueryBuilder for now
      query = Grant::Query::Builder(self).new(db_type)

      query
    end

    # Block form of `unscoped`: runs *block* with the default scope disabled for
    # this model, yielding a fresh unscoped `Grant::Query::Builder`, and restores
    # the previous scoping state afterward (even on exception). Returns whatever
    # the block returns. Use this for deliberate, bounded bypasses — e.g.
    # cross-tenant admin work under a `multitenant` default scope.
    #
    # ```
    # # See every post, including soft-deleted ones, just for this block:
    # all_posts = Post.unscoped { |q| q.select }
    #
    # # Deliberate cross-tenant read under a multitenant default scope:
    # Todo.unscoped { |q| q.where(done: true).select }
    # ```
    def unscoped(&block : Grant::Query::Builder(self) -> T) forall T
      # Temporarily disable default scope
      old_unscoped = _unscoped?
      self._unscoped = true

      db_type = if adapter.postgres?
                  Grant::Query::Builder::DbType::Pg
                elsif adapter.mysql?
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end

      query = Grant::Query::Builder(self).new(db_type)

      begin
        yield query
      ensure
        self._unscoped = old_unscoped
      end
    end

    # Chainable form of `unscoped`: returns a fresh `Grant::Query::Builder` with
    # **no** default scope applied, for chaining query methods directly. Unlike
    # the block form, scoping state is not toggled — this builder simply starts
    # from an unscoped base.
    #
    # ```
    # Post.unscoped.all.to_a           # every row, default scope ignored
    # Post.unscoped.where(id: 1).first # chain like any builder
    # Post.unscoped.delete_all         # bypass soft-delete scope to purge
    # ```
    def unscoped
      db_type = if adapter.postgres?
                  Grant::Query::Builder::DbType::Pg
                elsif adapter.mysql?
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end

      Grant::Query::Builder(self).new(db_type)
    end

    # Merges another query builder's clauses into this model's `current_scope`
    # and returns the combined builder. WHERE / ORDER / GROUP fields from
    # *other_scope* are appended; the **most restrictive** limit (smaller) and
    # the **largest** offset win. Lets you combine a scope built elsewhere with
    # this model's default scope.
    #
    # ```
    # extra = Post.unscoped.where(featured: true).limit(10)
    # Post.merge(extra).all # default scope + featured filter, limited to 10
    # ```
    def merge(other_scope : Grant::Query::Builder)
      current = current_scope

      # Merge where conditions
      other_scope.where_fields.each do |field|
        current.own_where_fields << field
      end

      # Merge order fields
      other_scope.order_fields.each do |field|
        current.own_order_fields << field
      end

      # Merge group fields
      other_scope.group_fields.each do |field|
        current.own_group_fields << field
      end

      # Use the most restrictive limit
      if other_limit = other_scope.limit
        if current_limit = current.limit
          current.limit!(Math.min(current_limit, other_limit))
        else
          current.limit!(other_limit)
        end
      end

      # Use the largest offset
      if other_offset = other_scope.offset
        if current_offset = current.offset
          current.offset!(Math.max(current_offset, other_offset))
        else
          current.offset!(other_offset)
        end
      end

      current
    end

    # Defines class-method delegations for *method_name* that forward to
    # `current_scope`, so a class-level query call (`Model.where(...)`) starts from
    # the scoped builder rather than a bare one — this is what makes the default
    # scope apply to top-level queries. Generates both a plain and a
    # block-accepting overload. Used internally to wire up `where`, `order`,
    # `group_by`, `limit`, `offset`, `includes`, `preload`, and `eager_load`.
    macro override_query_method(method_name)
    {% if method_name.id == "where" %}
      def where : Grant::Query::WhereChain(self)
        current_scope.where
      end

      def where(**kwargs) : Grant::Query::Builder(self)
        current_scope.where!(**kwargs)
      end

      def where(matches) : Grant::Query::Builder(self)
        current_scope.where!(matches)
      end

      def where(field : Symbol | String, operator : Symbol, value : Grant::Columns::Type) : Grant::Query::Builder(self)
        current_scope.where!(field, operator, value)
      end

      def where(stmt : String) : Grant::Query::Builder(self)
        current_scope.where!(stmt)
      end

      def where(stmt : String, value : Nil) : Grant::Query::Builder(self)
        current_scope.where!(stmt, value)
      end

      def where(stmt : String, values : Array) : Grant::Query::Builder(self)
        current_scope.where!(stmt, values)
      end

      def where(stmt : String, value : Grant::Columns::Type) : Grant::Query::Builder(self)
        current_scope.where!(stmt, value)
      end

      def where(stmt : String, first, second, *rest) : Grant::Query::Builder(self)
        values = [] of Grant::Columns::Type
        values << first.as(Grant::Columns::Type) << second.as(Grant::Columns::Type)
        rest.each { |value| values << value.as(Grant::Columns::Type) }
        current_scope.where!(stmt, values)
      end
    {% else %}
      # `current_scope` builds a fresh relation on every call that nothing else
      # references, so chain methods can use their in-place bang variants here
      # and skip a copy.
      {% in_place = %w(order lock group_by reorder reverse_order rewhere reselect regroup joins left_joins distinct having none includes preload eager_load limit offset unscope or).includes?(method_name.id.stringify) %}
      def {{method_name.id}}(*args, **kwargs)
        current_scope.{{method_name.id}}{% if in_place %}!{% end %}(*args, **kwargs)
      end

      def {{method_name.id}}(*args, **kwargs, &block)
        current_scope.{{method_name.id}}{% if in_place %}!{% end %}(*args, **kwargs) do |*yield_args|
          yield *yield_args
        end
      end
    {% end %}
  end

    # Override common query methods to respect default scope
    override_query_method where
    override_query_method order
    override_query_method lock
    override_query_method group_by
    override_query_method limit
    override_query_method offset
    override_query_method reorder
    override_query_method reverse_order
    override_query_method rewhere
    override_query_method reselect
    override_query_method regroup
    override_query_method joins
    override_query_method left_joins
    override_query_method distinct
    override_query_method having
    override_query_method none
    override_query_method includes
    override_query_method preload
    override_query_method eager_load
    override_query_method in_chunks
    override_query_method use_index
    override_query_method force_index
    override_query_method ignore_index
    override_query_method ids
    override_query_method pluck
    override_query_method pick
    override_query_method in_batches
    override_query_method annotate
    override_query_method explain
    override_query_method unscope
    override_query_method or
    override_query_method update_all
    override_query_method delete_all
    override_query_method destroy_all
    override_query_method delete
    override_query_method touch_all

    # Returns a lazy relation over this model, honoring the `default_scope`.
    # No SQL runs until the relation is iterated or a terminal method is
    # called, so it chains like any relation. Use `to_a` (or `select`) for an
    # `Array`, and `all(clause, params)` for the raw-SQL form.
    #
    # ```
    # Post.all                        # => relation, nothing executed yet
    # Post.all.where(published: true) # still lazy
    # Post.all.to_a                   # => Array(Post), default scope applied
    # ```
    def all : Grant::Query::Builder(self)
      current_scope
    end

    # Executes the `current_scope` (with default scope) and returns the matching
    # records. The scoping-aware override of the bare `select`.
    #
    # ```
    # Post.select # => Array(Post), default scope applied
    # ```
    def select
      current_scope.select
    end

    def select(*columns : Symbol | String)
      current_scope.select(*columns)
    end

    # Returns one matching record, or up to *count* records, from the current
    # scope, with no `ORDER BY`.
    def take : self?
      current_scope.take
    end

    def take(count : Int32) : Array(self)
      current_scope.take(count)
    end

    # Like `take`, but raises `Grant::Querying::NotFound` when there is no row.
    def take! : self
      current_scope.take!
    end

    # Returns the last *count* records of the current scope in ascending order.
    def last(count : Int32) : Array(self)
      current_scope.last(count)
    end

    {% for name in %w(second third fourth fifth forty_two second_to_last third_to_last) %}
      # Returns the {{name.id.gsub(/_/, " ")}} record of the current scope, or `nil`.
      def {{name.id}} : self?
        current_scope.{{name.id}}
      end

      # Like `{{name.id}}`, but raises `Grant::Querying::NotFound` when missing.
      def {{name.id}}! : self
        current_scope.{{name.id}}!
      end
    {% end %}

    # Column names that order an unordered relation for `first`, `last`, the
    # ordinal finders and `find_each`, ahead of the primary key. Empty unless
    # the model declares `implicit_order_column`.
    def implicit_order_columns : Array(String)
      [] of String
    end

    # Finds a record by primary key within the `default_scope`, or `nil` if none
    # matches (a soft-deleted row hidden by a default scope is not found).
    #
    # ```
    # Post.find(1) # => Post? (respecting default scope)
    # ```
    def find(id)
      current_scope.where(primary_name, :eq, id).first
    end

    # Finds a record by primary key within the `default_scope`, raising
    # `Grant::Querying::NotFound` when none matches.
    #
    # ```
    # Post.find!(1) # => Post (raises if absent or scoped out)
    # ```
    def find!(id)
      find(id) || raise Grant::Querying::NotFound.new("No #{self.name} found where #{primary_name} = #{id}")
    end
  end
end
