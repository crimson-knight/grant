require "../spec_helper"

# Compile-time driver for per-target column gating (Thread 1 §1.4).
#
# These specs shell out to the Crystal compiler so they can assert behaviour
# that differs *by build flag* — something a single in-process run cannot do,
# because the gated-out columns do not exist in this (default) build at all.
#
# For each `-Dgrant_target_*` flag we run spec/support/target_models/
# gated_columns_program.cr and assert which columns are present/absent and that
# JSON/YAML round-trips. We also assert that gating a `primary:` column fails to
# compile.
#
# These specs shell out to the compiler four times (~tens of seconds) and are
# therefore opt-in: run them with `crystal spec -Dgrant_compile_specs`. They are
# excluded from the default `crystal spec` run so they neither slow it down nor
# perturb its (pre-existing, environment-dependent) ordering. Skipped also when
# the `crystal` binary is not on PATH.

{% if flag?(:grant_compile_specs) %}
  private SPEC_DIR  = __DIR__
  private REPO_ROOT = File.expand_path("../..", SPEC_DIR)
  private PROGRAM   = File.join(REPO_ROOT, "spec", "support", "target_models", "gated_columns_program.cr")

  private def crystal_available? : Bool
    Process.run("crystal", ["--version"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
  rescue
    false
  end

  # Runs the gated-columns program under *flags*, returning its stdout parsed into
  # a `KEY => value` Hash.
  private def run_program(flags : Array(String)) : Hash(String, String)
    args = ["run", "--no-color", PROGRAM] + flags
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("crystal", args, output: stdout, error: stderr, chdir: REPO_ROOT)

    unless status.success?
      raise "crystal run #{flags.join(" ")} failed:\n#{stderr.to_s}\n#{stdout.to_s}"
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
        out = run_program(["-Dgrant_target_mobile", "-Dgrant_sqlite"])

        it "reports the active target and compiled adapter" do
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
        out = run_program(["-Dgrant_target_desktop", "-Dgrant_sqlite"])

        it "includes only the desktop-eligible gated column" do
          out["user_has_avatar_cache"].should eq("true") # [:mobile, :desktop]
          out["user_has_push_token"].should eq("false")  # [:mobile]
          out["user_has_password_digest"].should eq("false")
        end
      end

      describe "web target" do
        out = run_program(["-Dgrant_target_web", "-Dgrant_pg"])

        it "reports pg compiled in (one adapter per target)" do
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

      describe "primary-column gating" do
        it "fails to compile when a primary: true column is gated" do
          # Written inside the repo so the relative requires resolve exactly like
          # the working gated-columns program (which lives in the same directory).
          src = <<-CR
        require "../../../src/grant"
        require "../../../src/adapter/sqlite"

        class BadGatedPrimary < Grant::Base
          connection "primary"
          table bad_gated_primaries
          column id : Int64, primary: true, targets: [:web]
        end
        CR

          dir = File.join(REPO_ROOT, "spec", "support", "target_models")
          path = File.join(dir, "bad_gated_primary_tmp.cr")
          begin
            File.write(path, src)
            stderr = IO::Memory.new
            status = Process.run(
              "crystal", ["build", "--no-codegen", "--no-color", path, "-Dgrant_target_mobile"],
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
