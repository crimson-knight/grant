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
  macro included
    macro inherited
      # Flag to track if we're in unscoped mode
      class_property? _unscoped : Bool = false
    end
  end

  # Defines a named scope — a reusable class method *name* that applies *body*
  # (a lambda taking the current `Grant::Query::Builder` and returning a refined
  # one) on top of the model's `current_scope` (so the default scope, if any, is
  # included). Returns a `Grant::Query::Builder` you can chain further or
  # terminate with `all`/`first`/etc.
  #
  # ```
  # class Post < Grant::Base
  #   scope :published, ->(q : Grant::Query::Builder(Post)) { q.where(published: true) }
  # end
  #
  # Post.published       # => Grant::Query::Builder(Post)
  # Post.published.all   # => Array(Post) where published = true
  # Post.published.count # chain any query-builder method
  # ```
  macro scope(name, body)
    # Define on the model class
    def self.{{name.id}}
      query = current_scope
      {{body}}.call(query)
    end
  end

  # Defines a default scope applied to **every** query on this model — `all`,
  # `where`, `find`, named scopes, etc. — until `unscoped` is used. *block* runs
  # in the context of a fresh `Grant::Query::Builder` for this model (so you call
  # `where`, `order`, ... directly). Declaring it sets `_has_default_scope?` to
  # true and defines `apply_default_scope`, which `current_scope` invokes.
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

    def self.apply_default_scope(query : Grant::Query::Builder({{ @type }}))
      query.{{block.body}}
    end
  end

  module ClassMethods
    # Returns a fresh `Grant::Query::Builder` for this model with the
    # `default_scope` already applied (unless the model has no default scope or
    # execution is inside an `unscoped` block). This is the entry point every
    # class-level query method routes through, so the default scope is included
    # transparently.
    #
    # ```
    # Post.current_scope # => Grant::Query::Builder(Post) (+ default scope)
    # Post.current_scope.where(published: true).all
    # ```
    def current_scope
      db_type = case adapter.class.to_s
                when "Grant::Adapter::Pg"
                  Grant::Query::Builder::DbType::Pg
                when "Grant::Adapter::Mysql"
                  Grant::Query::Builder::DbType::Mysql
                else
                  Grant::Query::Builder::DbType::Sqlite
                end

      # Always use the standard QueryBuilder for now
      query = Grant::Query::Builder(self).new(db_type)

      # Apply default scope unless we're in unscoped mode
      if !_unscoped? && self.responds_to?(:_has_default_scope?) && self.responds_to?(:apply_default_scope) && self._has_default_scope?
        query = self.apply_default_scope(query)
      end

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

      db_type = case adapter.class.to_s
                when "Grant::Adapter::Pg"
                  Grant::Query::Builder::DbType::Pg
                when "Grant::Adapter::Mysql"
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
    # Post.unscoped.all                # every row, default scope ignored
    # Post.unscoped.where(id: 1).first # chain like any builder
    # Post.unscoped.delete_all         # bypass soft-delete scope to purge
    # ```
    def unscoped
      db_type = case adapter.class.to_s
                when "Grant::Adapter::Pg"
                  Grant::Query::Builder::DbType::Pg
                when "Grant::Adapter::Mysql"
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
        current.where_fields << field
      end

      # Merge order fields
      other_scope.order_fields.each do |field|
        current.order_fields << field
      end

      # Merge group fields
      other_scope.group_fields.each do |field|
        current.group_fields << field
      end

      # Use the most restrictive limit
      if other_limit = other_scope.limit
        if current_limit = current.limit
          current.limit(Math.min(current_limit, other_limit))
        else
          current.limit(other_limit)
        end
      end

      # Use the largest offset
      if other_offset = other_scope.offset
        if current_offset = current.offset
          current.offset(Math.max(current_offset, other_offset))
        else
          current.offset(other_offset)
        end
      end

      current
    end
  end

  # Defines a `QueryExtension` subclass of this model's `Grant::Query::Builder`
  # carrying the custom methods in *block*, and a `.extending` class method that
  # returns a fresh instance of it. Use it to add bespoke, chainable query
  # helpers beyond what named scopes express.
  #
  # ```
  # class Post < Grant::Base
  #   extending do
  #     def with_comments
  #       where("comments_count > ?", 0)
  #     end
  #   end
  # end
  #
  # Post.extending.with_comments # => a Post query builder, chainable
  # ```
  macro extending(&block)
    class QueryExtension < Grant::Query::Builder(\{{@type}})
      {{block.body}}
    end

    def self.extending
      QueryExtension.new(adapter.database_type)
    end
  end

  # Defines class-method delegations for *method_name* that forward to
  # `current_scope`, so a class-level query call (`Model.where(...)`) starts from
  # the scoped builder rather than a bare one — this is what makes the default
  # scope apply to top-level queries. Generates both a plain and a
  # block-accepting overload. Used internally to wire up `where`, `order`,
  # `group_by`, `limit`, `offset`, `includes`, `preload`, and `eager_load`.
  macro override_query_method(method_name)
    def self.{{method_name.id}}(*args, **kwargs)
      current_scope.{{method_name.id}}(*args, **kwargs)
    end
    
    def self.{{method_name.id}}(*args, **kwargs, &block)
      current_scope.{{method_name.id}}(*args, **kwargs) do |*yield_args|
        yield *yield_args
      end
    end
  end

  # Override common query methods to respect default scope
  override_query_method where
  override_query_method order
  override_query_method group_by
  override_query_method limit
  override_query_method offset
  override_query_method includes
  override_query_method preload
  override_query_method eager_load

  # Returns all records of this model, honoring the `default_scope`. Equivalent
  # to `current_scope.select`.
  #
  # ```
  # Post.all # => Array(Post), default scope applied
  # ```
  def self.all
    current_scope.select
  end

  # Executes the `current_scope` (with default scope) and returns the matching
  # records. The scoping-aware override of the bare `select`.
  #
  # ```
  # Post.select # => Array(Post), default scope applied
  # ```
  def self.select
    current_scope.select
  end

  # Finds a record by primary key within the `default_scope`, or `nil` if none
  # matches (a soft-deleted row hidden by a default scope is not found).
  #
  # ```
  # Post.find(1) # => Post? (respecting default scope)
  # ```
  def self.find(id)
    current_scope.find(id)
  end

  # Finds a record by primary key within the `default_scope`, raising
  # `Grant::Querying::NotFound` when none matches.
  #
  # ```
  # Post.find!(1) # => Post (raises if absent or scoped out)
  # ```
  def self.find!(id)
    current_scope.find!(id)
  end
end
