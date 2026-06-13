module Grant
  # Raised when an index hint cannot be honored and
  # `Grant.settings.index_hint_mode` is `:strict`.
  #
  # In the default `:warn` mode this is never raised — the query is re-run
  # without the hint instead (hints change the query plan, never the results).
  class UnsupportedIndexHintError < Exception
  end
end

# A single index hint attached to a query: its *kind* (`:use` / `:force` /
# `:ignore`) and the index names it applies to.
struct Grant::Query::IndexHint
  getter kind : Symbol
  getter names : Array(String)

  def initialize(@kind : Symbol, @names : Array(String))
  end
end

class Grant::Query::Builder(Model)
  # Index hints attached to this query, rendered per-adapter in the FROM clause.
  getter index_hints : Array(Grant::Query::IndexHint) = [] of Grant::Query::IndexHint

  # Suggest the query planner *consider* the named index(es).
  #
  # Renders `USE INDEX (...)` on MySQL and `INDEXED BY ...` on SQLite. On
  # PostgreSQL (no core planner hints) or any adapter that can't honor it, the
  # hint degrades per `Grant.settings.index_hint_mode` — the query still runs
  # and returns identical results.
  #
  # ```
  # User.where(tenant_id: t).use_index("idx_users_tenant").to_a
  # ```
  def use_index(*names : String) : self
    @index_hints << Grant::Query::IndexHint.new(:use, names.to_a)
    self
  end

  # Force the planner to use the named index (MySQL `FORCE INDEX`). On SQLite
  # `INDEXED BY` already forces a choice, so `force_index` maps to it. PG and
  # unsupported adapters degrade per `index_hint_mode`.
  def force_index(*names : String) : self
    @index_hints << Grant::Query::IndexHint.new(:force, names.to_a)
    self
  end

  # Tell the planner to avoid the named index (MySQL `IGNORE INDEX`). SQLite and
  # PG have no equivalent and degrade per `index_hint_mode`.
  def ignore_index(*names : String) : self
    @index_hints << Grant::Query::IndexHint.new(:ignore, names.to_a)
    self
  end

  # True when this query carries any index hints.
  def index_hints? : Bool
    !@index_hints.empty?
  end

  # Returns a dup of this query with all index hints stripped — used by the
  # safe-fallback path to re-run a hinted query plainly.
  protected def without_index_hints : self
    copy = dup
    copy.index_hints.clear
    copy
  end

  # Runs *block* (a terminal query execution) with index-hint safe fallback.
  #
  # If the block raises a "no such index" / unknown-key error from the adapter
  # AND this query carries index hints, the behavior depends on
  # `Grant.settings.index_hint_mode`:
  #
  # - `:warn`   — log and re-run via *retry_block* with hints stripped.
  # - `:ignore` — silently re-run with hints stripped.
  # - `:strict` — re-raise the original error.
  #
  # *retry_block* receives a hint-stripped copy of this query.
  protected def with_index_hint_fallback(&)
    yield self
  rescue ex
    raise ex unless index_hints?
    raise ex unless Model.adapter.index_missing_error?(ex)

    case Grant.settings.index_hint_mode
    when :strict
      raise ex
    when :ignore
      yield without_index_hints
    else # :warn
      Grant::Logs::Query.warn { "Index hint failed (#{ex.message}); re-running #{Model.name} query without hint" }
      yield without_index_hints
    end
  end
end

# Assembler-side rendering of the FROM clause with any index hint, via virtual
# dispatch on the adapter (no hard-coded adapter constants).
module Grant::Query::Assembler
  abstract class Base(Model)
    # `FROM <table> [<index hint>]`. When the query carries index hints, asks the
    # adapter to render them; an adapter that cannot honor a hint returns nil and
    # the hint degrades per `Grant.settings.index_hint_mode`.
    def from_clause : String
      hint = index_hint_sql
      hint ? "FROM #{table_name} #{hint}" : "FROM #{table_name}"
    end

    # Renders the adapter-specific index-hint SQL, or nil if there is no hint /
    # it degrades. In `:strict` mode, an unsupported hint raises
    # `Grant::UnsupportedIndexHintError`.
    def index_hint_sql : String?
      hints = @query.index_hints
      return nil if hints.empty?

      adapter = Model.adapter
      rendered = [] of String

      hints.each do |hint|
        clause = adapter.supports_index_hints? ? adapter.index_hint_clause(hint.kind, hint.names) : nil
        if clause
          rendered << clause
        else
          handle_unsupported_index_hint(hint)
        end
      end

      rendered.empty? ? nil : rendered.join(" ")
    end

    private def handle_unsupported_index_hint(hint : Grant::Query::IndexHint)
      case Grant.settings.index_hint_mode
      when :strict
        raise Grant::UnsupportedIndexHintError.new(
          "Adapter #{Model.adapter.class} cannot honor #{hint.kind.to_s.upcase} INDEX #{hint.names.join(", ")}")
      when :ignore
        # silently drop
      else # :warn
        Grant::Logs::Query.warn do
          "Index hint #{hint.kind.to_s.upcase} (#{hint.names.join(", ")}) not supported by " \
          "#{Model.adapter.class}; running #{Model.name} query without it"
        end
      end
    end
  end
end
