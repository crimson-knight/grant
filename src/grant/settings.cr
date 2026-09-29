module Grant
  class Settings
    property default_timezone : Time::Location = Time::Location.load(Grant::TIME_ZONE)

    def default_timezone=(name : String)
      @default_timezone = Time::Location.load(name)
    end

    # How Grant behaves when an index hint cannot be honored — either because
    # the adapter has no hint syntax (e.g. PostgreSQL), the hint kind is
    # unsupported (e.g. SQLite `IGNORE`), or the named index does not exist.
    #
    # - `:warn` (default) — log a warning and re-run the query WITHOUT the hint.
    #   Always succeeds; hints change the plan, never the results.
    # - `:strict` — raise `Grant::UnsupportedIndexHintError` (or surface the DB
    #   error) so misconfigured hints fail loudly.
    # - `:ignore` — silently drop the unsupported hint (no warning, no error).
    #
    # See `docs/large_tables.md`.
    property index_hint_mode : Symbol = :warn

    # The maximum number of values Grant will place in a single `IN (...)`
    # clause before transparently splitting the query into multiple chunked
    # queries. Drivers and databases cap the number of bind parameters per
    # statement (e.g. SQLite's `SQLITE_MAX_VARIABLE_NUMBER`); chunking keeps a
    # massive `where(col: huge_array)` from blowing that cap.
    #
    # Per-query override: `.in_chunks(of: n)`. See `docs/large_tables.md`.
    property in_clause_limit : Int32 = 1000

    # When true, `Grant::StatementInvalid#binds` holds each bind value (cut to
    # 64 characters, at most 20 kept) instead of `[FILTERED]`. Leave it off in
    # production so an exception message or log line cannot leak a secret;
    # turn it on while configuring a development environment.
    property? capture_statement_bind_values : Bool = false

    # Role name that `connected_to(role: ...)` treats as the writer. `:primary`,
    # the role of a model that never chose one, is an alias of it.
    getter writing_role : Symbol = :writing

    # Role name that `connected_to(role: ...)` treats as the reader. Switching to
    # it prevents writes, as in ActiveRecord.
    getter reading_role : Symbol = :reading

    def writing_role=(role : Symbol)
      raise ArgumentError.new("writing_role must differ from reading_role (got #{role.inspect})") if role == @reading_role
      @writing_role = role
    end

    def reading_role=(role : Symbol)
      raise ArgumentError.new("reading_role must differ from writing_role (got #{role.inspect})") if role == @writing_role
      @reading_role = role
    end

    # Legacy implicit ordering. When `true`, an unordered SELECT gets
    # `ORDER BY <primary key> DESC` appended (Grant's behavior before the
    # relation-core rework). When `false` (the default), unordered relations
    # carry no `ORDER BY`, like ActiveRecord; `first`, `last`, the ordinal
    # finders and `find_each` still order by `implicit_order_column`s and the
    # primary key. The flag exists for one release so apps that depended on
    # the newest-first default can opt back in.
    property implicit_order : Bool = false

    # Attribute names (String, matched as a case-insensitive substring) and
    # patterns (Regex) whose values `inspect` prints as `[FILTERED]`, for every
    # model. Encrypted columns are always filtered. A model adds its own with
    # `filter_attributes :token`.
    property filter_attributes : Array(String | Regex) = [] of String | Regex

    # The most `load_async`/`async_*` queries that run at once, across the
    # process. Each one holds a pool connection while it runs, so keep this at
    # or below the connection pool size; later queries wait for a free slot
    # instead of starving the pool. Like ActiveRecord's async executor, the
    # default is 4.
    getter async_pool_size : Int32 = 4

    def async_pool_size=(size : Int32)
      raise ArgumentError.new("async_pool_size must be at least 1 (got #{size})") if size < 1
      @async_pool_size = size
    end

    # The most statements one query cache (`Grant.cache { }`) keeps; the least
    # recently used entry is dropped first. `0` turns caching off.
    getter query_cache_max_entries : Int32 = 100

    def query_cache_max_entries=(size : Int32)
      raise ArgumentError.new("query_cache_max_entries must not be negative (got #{size})") if size < 0
      @query_cache_max_entries = size
    end

    def index_hint_mode=(mode : Symbol)
      unless {:warn, :strict, :ignore}.includes?(mode)
        raise ArgumentError.new("index_hint_mode must be :warn, :strict, or :ignore (got #{mode.inspect})")
      end
      @index_hint_mode = mode
    end
  end

  def self.settings
    @@settings ||= Settings.new
  end
end
