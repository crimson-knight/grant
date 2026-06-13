require "../spec_helper"

# Compile-time driver for per-target column gating.
#
# These specs shell out to the Crystal compiler so they can assert behaviour
# that differs *by build* — something a single in-process run cannot do, because
# the gated-out columns do not exist in this (default, untargeted) build at all.
#
# The new mechanism uses **no `-D` flags**: a build selects its target by which
# `grant/target/<name>` file it `require`s (which sets the top-level
# `GRANT_COMPILE_TARGET` constant). So instead of recompiling one source under
# different flags, we run three thin per-target entrypoints
# (spec/support/target_models/entry_{mobile,desktop,web}.cr), each of which
# requires its adapter + target file before the *shared* models in
# gated_models.cr expand. We assert which columns are present/absent and that
# JSON/YAML round-trips per target. We also assert that gating a `primary:`
# column fails to compile.
#
# These specs shell out to the compiler several times (~tens of seconds) and are
# therefore opt-in: run them with `crystal spec -Dgrant_compile_specs`. They are
# excluded from the default `crystal spec` run so they neither slow it down nor
# perturb its (pre-existing, environment-dependent) ordering. Skipped also when
# the `crystal` binary is not on PATH.

{% if flag?(:grant_compile_specs) %}
  private SPEC_DIR   = __DIR__
  private REPO_ROOT  = File.expand_path("../..", SPEC_DIR)
  private TARGET_DIR = File.join(REPO_ROOT, "spec", "support", "target_models")

  private def crystal_available? : Bool
    Process.run("crystal", ["--version"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
  rescue
    false
  end

  # Runs the per-target *entry* program (e.g. "entry_mobile"), returning its
  # stdout parsed into a `KEY => value` Hash.
  private def run_entry(entry : String) : Hash(String, String)
    program = File.join(TARGET_DIR, "#{entry}.cr")
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("crystal", ["run", "--no-color", program], output: stdout, error: stderr, chdir: REPO_ROOT)

    unless status.success?
      raise "crystal run #{entry} failed:\n#{stderr.to_s}\n#{stdout.to_s}"
    end

    result = {} of String => String
    stdout.to_s.each_line do |line|
      if idx = line.index('=')
        result[line[0...idx]] = line[(idx + 1)..]
      end
    end
    result
  end

  describe "per-target column gating (compile-time)" do
    if crystal_available?
      describe "mobile target" do
        out = run_entry("entry_mobile")

        it "reports the active target and compiled adapter" do
          out["TARGET"].should eq("mobile")
          out["TARGETS"].should eq("grant_target_mobile")
          out["COMPILED"].should eq("sqlite")
        end

        it "keeps shared columns present" do
          out["user_has_id"].should eq("true")
          out["user_has_email"].should eq("true")
        end

        it "includes device-only gated columns and excludes server-only ones" do
          out["user_has_push_token"].should eq("true")
          out["user_has_avatar_cache"].should eq("true")
          out["user_has_password_digest"].should eq("false")
        end

        it "round-trips JSON without the gated server-only column" do
          out["json_roundtrip_email"].should eq("a@example.com")
          out["json_has_password_digest"].should eq("false")
          out["RESULT"].should eq("OK")
        end

        it "gates a column on an STI subclass" do
          out["admin_has_name"].should eq("true")
          out["admin_has_admin_note"].should eq("true")
          out["admin_has_server_secret"].should eq("false")
          out["admin_yaml_roundtrip_name"].should eq("root")
          out["admin_yaml_has_server_secret"].should eq("false")
        end
      end

      describe "desktop target" do
        out = run_entry("entry_desktop")

        it "reports the active target" do
          out["TARGET"].should eq("desktop")
          out["TARGETS"].should eq("grant_target_desktop")
        end

        it "includes only the desktop-eligible gated column" do
          out["user_has_avatar_cache"].should eq("true") # [:mobile, :desktop]
          out["user_has_push_token"].should eq("false")  # [:mobile]
          out["user_has_password_digest"].should eq("false")
        end
      end

      describe "web target" do
        out = run_entry("entry_web")

        it "reports pg compiled in (one adapter per target)" do
          out["TARGET"].should eq("web")
          out["TARGETS"].should eq("grant_target_web")
          out["COMPILED"].should eq("pg")
        end

        it "includes server-only gated columns and excludes device-only ones" do
          out["user_has_password_digest"].should eq("true")
          out["user_has_push_token"].should eq("false")
          out["user_has_avatar_cache"].should eq("false")
        end

        it "round-trips the gated server-only column through JSON" do
          out["json_has_password_digest"].should eq("true")
          out["json_roundtrip_password_digest"].should eq("hashed")
        end

        it "round-trips a gated STI subclass column through YAML" do
          out["admin_has_server_secret"].should eq("true")
          out["admin_yaml_has_server_secret"].should eq("true")
          out["admin_yaml_roundtrip_server_secret"].should eq("s3cr3t")
          out["RESULT"].should eq("OK")
        end
      end

      describe "untargeted build" do
        # No `grant/target/<name>` required → GRANT_COMPILE_TARGET unset → every
        # gated column is present (the default/spec build behaviour).
        it "keeps every gated column when no target is selected" do
          src = <<-CR
          require "../../../src/grant"
          require "../../../src/adapter/sqlite"

          Grant::ConnectionRegistry.establish_connection(
            database: "primary", adapter: Grant::Adapter::Sqlite, url: "sqlite3://%3Amemory%3A")

          class UntargetedUser < Grant::Base
            connection "primary"
            table untargeted_users
            column id : Int64, primary: true
            column push_token : String?, targets: [:mobile]
            column password_digest : String?, targets: [:web]
          end

          puts "target=\#{Grant.compile_target.inspect}"
          puts "fields=\#{UntargetedUser.fields.join(",")}"
          CR

          path = File.join(TARGET_DIR, "untargeted_tmp.cr")
          begin
            File.write(path, src)
            stdout = IO::Memory.new
            status = Process.run("crystal", ["run", "--no-color", path], output: stdout, error: Process::Redirect::Close, chdir: REPO_ROOT)
            status.success?.should be_true
            output = stdout.to_s
            output.should contain("target=nil")
            output.should contain("push_token")
            output.should contain("password_digest")
          ensure
            File.delete(path) if File.exists?(path)
          end
        end
      end

      describe "primary-column gating" do
        it "fails to compile when a primary: true column is gated" do
          # Written inside the repo so the relative requires resolve exactly like
          # the per-target entrypoints (which live in the same directory).
          src = <<-CR
          require "../../../src/grant"
          require "../../../src/adapter/sqlite"
          require "../../../src/target/web"

          class BadGatedPrimary < Grant::Base
            connection "primary"
            table bad_gated_primaries
            column id : Int64, primary: true, targets: [:web]
          end
          CR

          path = File.join(TARGET_DIR, "bad_gated_primary_tmp.cr")
          begin
            File.write(path, src)
            stderr = IO::Memory.new
            status = Process.run(
              "crystal", ["build", "--no-codegen", "--no-color", path],
              output: Process::Redirect::Close, error: stderr, chdir: REPO_ROOT
            )

            status.success?.should be_false
            stderr.to_s.should contain("cannot be gated with `targets:`")
          ensure
            File.delete(path) if File.exists?(path)
          end
        end
      end
    else
      pending "crystal compiler not available; skipping compile-time target gating specs"
    end
  end
{% end %}
