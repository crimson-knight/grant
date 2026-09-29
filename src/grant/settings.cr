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
