# Compile-target support for Grant.
#
# Grant compiles the **same model classes** for different deployment targets —
# a mobile app, a desktop app, a web server — choosing the database adapter (and
# optionally a different *column set*) per target, entirely at compile time. It
# does this the idiomatic Crystal way, with **no `-D` flags**:
#
# * **Adapter selection is just a `require`.** The build entrypoint requires the
#   one adapter it needs (`require "grant/adapter/pg"`, etc.). A single binary
#   never links an adapter it does not require. For a monorepo, use Crystal's
#   native `shard.yml` `targets:` with one `main:` per build variant.
# * **The build target is a plain top-level constant**, `GRANT_COMPILE_TARGET`,
#   set by requiring one of `grant/target/{mobile,desktop,web}` (each of which is
#   a one-line `GRANT_COMPILE_TARGET = :mobile` etc.) **before** your models. A
#   custom target is just `GRANT_COMPILE_TARGET = :your_target` set yourself
#   before requiring models. The `column` macro reads it via `@top_level` to gate
#   per-target columns.
#
# Single-target apps need **zero** target machinery: require an adapter, define
# models, done. The target constant only matters if you use `targets:` on a
# `column`.
#
# See `docs/compile_target_adapters.md` for the full design (including the
# deliberate device → API → DB boundary: a device never talks to a cloud
# database directly).
module Grant
  # The active build target symbol (`:mobile` / `:desktop` / `:web`, or a custom
  # symbol), or `nil` when no target was selected (the default/spec build, where
  # every gated column is present and Grant behaves as a plain multi-adapter
  # library).
  #
  # Reads the top-level `GRANT_COMPILE_TARGET` constant set by
  # `require "grant/target/<name>"` (or by the app directly). Nil-safe: an
  # untargeted build returns `nil`.
  #
  # ```
  # # default build (no target required)
  # Grant.compile_target # => nil
  #
  # # after `require "grant/target/web"`
  # Grant.compile_target # => :web
  # ```
  def self.compile_target : Symbol?
    {% if @top_level.has_constant?("GRANT_COMPILE_TARGET") %}
      {{ @top_level.constant("GRANT_COMPILE_TARGET") }}
    {% else %}
      nil
    {% end %}
  end

  # Returns the active build target as a single-element array of its flag-style
  # name (e.g. `["grant_target_web"]`), or an empty array when no target is set.
  #
  # Retained for diagnostics and for the `AdapterNotAvailableError` message. The
  # name is derived from `compile_target` (`:web` ⇒ `"grant_target_web"`) so the
  # guard-rail message reads the same as before, even though there is no longer
  # any `-D` flag behind it.
  #
  # ```
  # Grant.active_targets # => [] (default build)
  # # after `require "grant/target/mobile"`
  # Grant.active_targets # => ["grant_target_mobile"]
  # ```
  def self.active_targets : Array(String)
    if target = compile_target
      ["grant_target_#{target}"]
    else
      [] of String
    end
  end

  # True when the symbol *target* matches the active `GRANT_COMPILE_TARGET`.
  # Used by the per-target `column` gating and for app-level conditionals.
  #
  # ```
  # # after `require "grant/target/mobile"`
  # Grant.target?(:mobile) # => true
  # Grant.target?(:web)    # => false
  # ```
  def self.target?(target : Symbol) : Bool
    compile_target == target
  end

  # The database adapters compiled into this binary, derived at **compile time**
  # from which `Grant::Adapter::*` classes were `require`d — e.g. `["sqlite"]`
  # for a build that did `require "grant/adapter/sqlite"`.
  #
  # This is the authoritative list used in the `AdapterNotAvailableError` message
  # and for diagnostics. Because adapter selection is now a plain `require` (no
  # `-D` presence flag), this simply reflects the adapter classes that exist —
  # there is no flag to forget to set.
  #
  # ```
  # # after `require "grant/adapter/sqlite"`
  # Grant.compiled_adapters # => ["sqlite"]
  # ```
  def self.compiled_adapters : Array(String)
    {% begin %}
      adapters = [] of String
      {% if Grant::Adapter.has_constant?("Sqlite") %} adapters << "sqlite" {% end %}
      {% if Grant::Adapter.has_constant?("Pg") %} adapters << "pg" {% end %}
      {% if Grant::Adapter.has_constant?("Mysql") %} adapters << "mysql" {% end %}
      adapters
    {% end %}
  end
end
