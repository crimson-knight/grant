require "../../spec_helper"
require "../../support/crystal_compiler"

describe "saving a model first built in an instance variable initializer" do
  # Compiled as its own program: see spec/support/ivar_initializer_save_probe.cr.
  it "saves, and keeps class-level settings, as a generated Amber app does" do
    source = File.expand_path("../../support/ivar_initializer_save_probe.cr", __DIR__)
    probe = File.join(Dir.tempdir, "grant_ivar_initializer_save_probe_#{Process.pid}")
    database = File.join(Dir.tempdir, "grant_ivar_initializer_save_probe_#{Process.pid}.db")

    begin
      build_output = IO::Memory.new
      build = Process.run(spec_crystal_compiler, ["build", source, "-o", probe], output: build_output, error: build_output)
      build.success?.should be_true, build_output.to_s

      run_output = IO::Memory.new
      run = Process.run(probe, [database], output: run_output, error: run_output)
      run.success?.should be_true, run_output.to_s
      run_output.to_s.should eq(<<-OUT)
        saved=true id=1
        found=Ruby
        replica_lag_threshold=00:00:02
        subclass_default_scope=true

        OUT
    ensure
      File.delete(probe) if File.exists?(probe)
      File.delete(database) if File.exists?(database)
    end
  end
end
