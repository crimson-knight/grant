# Compile-target adapter selection for Grant.
#
# Grant models are compiled for exactly **one** database adapter per build
# target. The adapter is chosen at compile time by a `-Dgrant_target_<x>` flag
# (mobile / desktop / web) which, by convention, maps to one adapter-presence
# flag (`-Dgrant_sqlite` / `-Dgrant_pg` / `-Dgrant_mysql`). A single binary
# never links more than one adapter it does not use.
#
# See `docs/compile_target_adapters.md` for the full design (including the
# deliberate device → API → DB boundary: a device never talks to a cloud
# database directly).
module Grant
  # The three semantic build targets. Read at compile time from the
  # `grant_target_*` flags; used for diagnostics and the guard-rail error.
  TARGET_FLAGS = {mobile: "grant_target_mobile", desktop: "grant_target_desktop", web: "grant_target_web"}

  # The three adapter-presence flags. Gate the actual adapter `require`s / driver
  # linkage and populate `Grant.compiled_adapters`.
  ADAPTER_FLAGS = {sqlite: "grant_sqlite", pg: "grant_pg", mysql: "grant_mysql"}

  # Returns the active build target flag name(s) — e.g. `["grant_target_mobile"]`.
  #
  # Normally exactly one is set; an empty result means no `grant_target_*` flag
  # was passed (the default/spec build, where Grant behaves as a single
  # plain-old-multi-adapter library). More than one is unusual but reported
  # faithfully (the flags are mutually exclusive only by convention).
  def self.active_targets : Array(String)
    {% begin %}
      targets = [] of String
      {% if flag?(:grant_target_mobile) %} targets << "grant_target_mobile" {% end %}
      {% if flag?(:grant_target_desktop) %} targets << "grant_target_desktop" {% end %}
      {% if flag?(:grant_target_web) %} targets << "grant_target_web" {% end %}
      targets
    {% end %}
  end

  # True when the symbol *target* (`:mobile` / `:desktop` / `:web`) matches an
  # active `grant_target_*` flag. Used by the per-target `column` gating.
  def self.target?(target : Symbol) : Bool
    {% begin %}
      case target
      when :mobile  then {{ flag?(:grant_target_mobile) }}
      when :desktop then {{ flag?(:grant_target_desktop) }}
      when :web     then {{ flag?(:grant_target_web) }}
      else               false
      end
    {% end %}
  end

  # The database adapters compiled into this binary, derived at **compile time**
  # from the `grant_<name>` presence flags — e.g. `["sqlite"]` for a build run
  # with `-Dgrant_sqlite`.
  #
  # This is the authoritative list used in the `AdapterNotAvailableError` message
  # and for diagnostics. It reflects intent declared via flags; a build that
  # `require`s an adapter directly without its presence flag will still link the
  # adapter but will not list it here (set the flag, or use `configure_target`,
  # to keep diagnostics accurate).
  def self.compiled_adapters : Array(String)
    {% begin %}
      adapters = [] of String
      {% if flag?(:grant_sqlite) %} adapters << "sqlite" {% end %}
      {% if flag?(:grant_pg) %} adapters << "pg" {% end %}
      {% if flag?(:grant_mysql) %} adapters << "mysql" {% end %}
      adapters
    {% end %}
  end

  # `Grant.configure_target` — thin, ergonomic sugar over the blessed,
  # hand-rollable guarded-`require` pattern. An app calls this **once** in its
  # boot/config file. It expands to top-level, flag-guarded `require`s of the one
  # adapter the active target needs, plus the `establish_connection` calls.
  #
  # ```
  # Grant.configure_target do
  #   mobile_or_desktop do
  #     use Grant::Adapter::Sqlite
  #     primary url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" }
  #   end
  #   web do
  #     use Grant::Adapter::Pg
  #     primary url: ENV["DATABASE_URL"]
  #     replica url: ENV["DATABASE_REPLICA_URL"]
  #   end
  # end
  # ```
  #
  # `require` is a top-level-only construct, so the macro emits the guarded
  # requires at the top level (not nested in a method).
  #
  # ## Hand-rolled fallback (always works, no macro)
  #
  # The macro is *only* organisational sugar. The exact pattern it expands to is
  # fully supported by hand and is the recommended fallback when you want full
  # control:
  #
  # ```
  # {% if flag?(:grant_target_mobile) || flag?(:grant_target_desktop) %}
  #   require "grant/adapter/sqlite"
  #   Grant::ConnectionRegistry.establish_connection(
  #     database: "primary", adapter: Grant::Adapter::Sqlite,
  #     url_provider: -> { "sqlite3://#{Device.app_support_dir}/app.db" })
  # {% elsif flag?(:grant_target_web) %}
  #   require "grant/adapter/pg"
  #   Grant::ConnectionRegistry.establish_connection(
  #     database: "primary", adapter: Grant::Adapter::Pg, url: ENV["DATABASE_URL"])
  # {% end %}
  # ```
  macro configure_target(&block)
    {% if block.body.is_a?(Expressions) %}
      {% calls = block.body.expressions %}
    {% else %}
      {% calls = [block.body] %}
    {% end %}

    {% for grp in calls %}
      {% gname = grp.name.id.stringify %}

      # Decide, at compile time, whether this group's body should be emitted for
      # the active target. Exactly one of these is true in a normal build.
      {% emit_group = false %}
      {% if gname == "mobile_or_desktop" %}
        {% emit_group = flag?(:grant_target_mobile) || flag?(:grant_target_desktop) %}
      {% elsif gname == "mobile" %}
        {% emit_group = flag?(:grant_target_mobile) %}
      {% elsif gname == "desktop" %}
        {% emit_group = flag?(:grant_target_desktop) %}
      {% elsif gname == "web" %}
        {% emit_group = flag?(:grant_target_web) %}
      {% else %}
        {% raise "Grant.configure_target: unknown target group '#{gname}'. " \
                 "Use one of: mobile_or_desktop, mobile, desktop, web." %}
      {% end %}

      {% if emit_group %}
        # The group body is a `use <Adapter>` declaration plus one or more role
        # declarations (primary/replica/writer/reader/custom-db-name), each with
        # `url:` or `url_provider:`. We process its statements *in place* (never
        # re-emitting the block body as a macro argument, which would splice
        # multiple statements into a single `(...)` and fail to parse).
        {% gbody = grp.block.body %}
        {% if gbody.is_a?(Expressions) %}
          {% stmts = gbody.expressions %}
        {% else %}
          {% stmts = [gbody] %}
        {% end %}

        # Locate the `use <Adapter>` declaration to know which shard to require
        # and which adapter class to register against.
        {% adapter = nil %}
        {% for stmt in stmts %}
          {% if stmt.is_a?(Call) && stmt.name.id.stringify == "use" %}
            {% adapter = stmt.args.first %}
          {% end %}
        {% end %}

        {% if adapter == nil %}
          {% raise "Grant.configure_target: target group '#{gname}' must declare its adapter with `use <Adapter>` (e.g. `use Grant::Adapter::Sqlite`)." %}
        {% end %}

        # Guarded `require` of exactly the one adapter shard this target needs.
        {% adapter_name = adapter.id.stringify %}
        {% if adapter_name.ends_with?("Sqlite") %}
          require "grant/adapter/sqlite"
        {% elsif adapter_name.ends_with?("Pg") %}
          require "grant/adapter/pg"
        {% elsif adapter_name.ends_with?("Mysql") %}
          require "grant/adapter/mysql"
        {% else %}
          {% raise "Grant.configure_target: unsupported adapter #{adapter_name}. Expected Grant::Adapter::{Sqlite,Pg,Mysql}." %}
        {% end %}

        {% for stmt in stmts %}
          {% if stmt.is_a?(Call) && stmt.name.id.stringify != "use" %}
            {% role_name = stmt.name.id.stringify %}
            {% database = (role_name == "primary" || role_name == "writer" || role_name == "replica" || role_name == "reader") ? "primary" : role_name %}
            {% role_sym = (role_name == "replica" || role_name == "reader") ? :reading : ((role_name == "writer") ? :writing : :primary) %}

            {% named = stmt.named_args || [] of Nil %}
            {% url_arg = nil %}
            {% url_provider_arg = nil %}
            {% for na in named %}
              {% if na.name.id.stringify == "url" %} {% url_arg = na.value %} {% end %}
              {% if na.name.id.stringify == "url_provider" %} {% url_provider_arg = na.value %} {% end %}
            {% end %}

            {% if url_provider_arg != nil %}
              Grant::ConnectionRegistry.establish_connection(
                database: {{database}},
                adapter: {{adapter}},
                url_provider: {{url_provider_arg}},
                role: {{role_sym}}
              )
            {% elsif url_arg != nil %}
              Grant::ConnectionRegistry.establish_connection(
                database: {{database}},
                adapter: {{adapter}},
                url: {{url_arg}},
                role: {{role_sym}}
              )
            {% else %}
              {% raise "Grant.configure_target: role `#{role_name}` in group '#{gname}' needs `url:` or `url_provider:`." %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
  end
end
