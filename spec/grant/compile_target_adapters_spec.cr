require "../spec_helper"

# Specs for the compile-target mechanism (idiomatic, no `-D` flags).
#
# Covered here (runtime behaviour, adapter-agnostic, run under SQLite):
#   * lazy URL provider — not invoked at registration, invoked once on first use
#   * the AdapterNotAvailableError guard rail and its message contents
#   * Grant.compiled_adapters / Grant.active_targets / Grant.target? diagnostics
#
# Adapter selection is now just which adapter you `require`; the build target is
# the top-level `GRANT_COMPILE_TARGET` constant set by `require
# "grant/target/<name>"`. Per-target column gating (present/absent by target,
# the primary-gating compile error, STI + serialization round-trip) cannot be
# observed in a single in-process build, so it is exercised by running the
# per-target entrypoints in spec/support/target_models/ — see
# spec/grant/compile_target_columns_compile_spec.cr for the driver that shells
# out to `crystal run`.

# Minimal adapter that records when its URL was resolved, so we can prove the
# lazy provider is not called at registration time.
class TargetSpecMockAdapter < Grant::Adapter::Base
  QUOTING_CHAR = '"'

  def clear(table_name : String); end

  def insert(table_name : String, fields, params, lastval) : Int64
    0_i64
  end

  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options); end

  def update(table_name : String, primary_name : String, fields, params); end

  def delete(table_name : String, primary_name : String, value); end

  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    true
  end

  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    true
  end

  def supports_savepoints? : Bool
    true
  end
end

describe "Grant compile-target mechanism" do
  # NOTE: this spec deliberately does NOT call ConnectionRegistry.clear_all and
  # does NOT touch the default "sqlite" connection. It registers only uniquely
  # named throwaway databases (lazy_db, eager_db, …) so it leaves global
  # registry state untouched and does not perturb the rest of the (ordering- and
  # environment-sensitive) suite. Leaving these inert test entries registered is
  # harmless — no other spec references them.

  describe "lazy URL provider" do
    it "does not invoke the provider at registration time" do
      called = 0
      Grant::ConnectionRegistry.establish_connection(
        database: "lazy_db",
        adapter: TargetSpecMockAdapter,
        url_provider: -> {
          called += 1
          "sqlite3://lazy.db"
        }
      )

      # Registered, but the provider has NOT run yet.
      called.should eq(0)
      Grant::ConnectionRegistry.connection_exists?("lazy_db", :primary).should be_true
    end

    it "invokes the provider exactly once on first pool build, then memoises it" do
      called = 0
      Grant::ConnectionRegistry.establish_connection(
        database: "lazy_once_db",
        adapter: TargetSpecMockAdapter,
        url_provider: -> {
          called += 1
          "sqlite3://lazy_once.db"
        }
      )

      called.should eq(0)

      # First adapter resolution materialises the connection → provider runs.
      adapter = Grant::ConnectionRegistry.get_adapter("lazy_once_db", :primary)
      called.should eq(1)
      adapter.url.should start_with("sqlite3://lazy_once.db")

      # Subsequent resolutions reuse the memoised URL — provider does not re-run.
      Grant::ConnectionRegistry.get_adapter("lazy_once_db", :primary)
      Grant::ConnectionRegistry.get_adapter("lazy_once_db", :primary)
      called.should eq(1)
    end

    it "still supports the eager url overload unchanged" do
      Grant::ConnectionRegistry.establish_connection(
        database: "eager_db",
        adapter: TargetSpecMockAdapter,
        url: "sqlite3://eager.db"
      )

      adapter = Grant::ConnectionRegistry.get_adapter("eager_db", :primary)
      adapter.url.should start_with("sqlite3://eager.db")
    end

    it "supports a lazy url_provider via establish_connections" do
      called = 0
      provider = -> {
        called += 1
        "sqlite3://lazy_multi.db"
      }

      Grant::ConnectionRegistry.establish_connections({
        "lazy_multi_db" => {adapter: TargetSpecMockAdapter, url_provider: provider},
      })

      called.should eq(0)
      Grant::ConnectionRegistry.get_adapter("lazy_multi_db", :primary)
      called.should eq(1)
    end
  end

  describe "guard rail: AdapterNotAvailableError" do
    it "raises a clear error naming the connection when none is registered" do
      ex = expect_raises(Grant::AdapterNotAvailableError) do
        Grant::ConnectionRegistry.get_adapter("never_registered_db", :primary)
      end

      ex.message.not_nil!.should contain("never_registered_db")
    end

    it "includes the active target(s), compiled adapters, and an actionable fix" do
      ex = expect_raises(Grant::AdapterNotAvailableError) do
        Grant::ConnectionRegistry.get_adapter("missing_db", :primary)
      end

      msg = ex.message.not_nil!
      msg.should contain("Active build target(s)")
      msg.should contain("Adapters compiled in")
      msg.should contain("Registered connections")
      # Actionable fix guidance — points at establish_connection and the
      # adapter require (no `-D` flags, no configure_target).
      msg.should contain("establish_connection")
      msg.should contain("require \"grant/adapter/<name>\"")
    end
  end

  describe "diagnostics" do
    it "Grant.compiled_adapters reflects the adapter classes required" do
      # The spec suite requires `src/adapter/**`, so every adapter class exists
      # and is reported. (A real single-target build requires exactly one.)
      Grant.compiled_adapters.should contain("sqlite")
      Grant.compiled_adapters.should contain("pg")
      Grant.compiled_adapters.should contain("mysql")
    end

    it "Grant.compile_target is nil when no GRANT_COMPILE_TARGET is set" do
      Grant.compile_target.should be_nil
    end

    it "Grant.active_targets is empty when no target is selected" do
      Grant.active_targets.should eq([] of String)
    end

    it "Grant.target? returns false for every target in the untargeted build" do
      Grant.target?(:mobile).should be_false
      Grant.target?(:desktop).should be_false
      Grant.target?(:web).should be_false
    end
  end
end
