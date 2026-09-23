require "../../spec_helper"

describe "#abort!" do
  before_each do
    CallbackWithAbort.clear
  end

  context "when create" do
    it "rolls back if abort at before_validation" do
      cwa = CallbackWithAbort.new(abort_at: "before_validation", do_abort: true)
      cwa.history = IO::Memory.new

      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at before_validation."])
      cwa.history.to_s.strip.should eq <<-RUNS
        after_rollback
        RUNS
      cwa.persisted?.should be_false
      cwa.new_record?.should be_true
      cwa.changed?.should be_false
      CallbackWithAbort.find("before_validation").should be_nil
    end

    it "rolls back if abort at after_validation" do
      cwa = CallbackWithAbort.new(abort_at: "after_validation", do_abort: true)
      cwa.history = IO::Memory.new

      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at after_validation."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_rollback
        RUNS
      cwa.persisted?.should be_false
      cwa.new_record?.should be_true
      cwa.changed?.should be_false
      CallbackWithAbort.find("after_validation").should be_nil
    end

    it "doesn't run other callbacks if abort at before_save" do
      cwa = CallbackWithAbort.new(abort_at: "before_save", do_abort: true)
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at before_save."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        after_rollback
        RUNS
      cwa.persisted?.should be_false
      cwa.new_record?.should be_true
      cwa.changed?.should be_false
      CallbackWithAbort.find("before_save").should be_nil
    end

    it "only runs before_save if abort at before_create" do
      cwa = CallbackWithAbort.new(abort_at: "before_create", do_abort: true)
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at before_create."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        before_save
        after_rollback
        RUNS
      cwa.persisted?.should be_false
      cwa.new_record?.should be_true
      cwa.changed?.should be_false
      CallbackWithAbort.find("before_create").should be_nil
    end

    it "rolls back if abort at after_create" do
      cwa = CallbackWithAbort.new(abort_at: "after_create", do_abort: true)
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at after_create."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        before_save
        before_create
        after_rollback
        RUNS
      cwa.persisted?.should be_false
      cwa.new_record?.should be_true
      cwa.changed?.should be_false
      CallbackWithAbort.find("after_create").should be_nil
    end

    it "rolls back if abort at after_save" do
      cwa = CallbackWithAbort.new(abort_at: "after_save", do_abort: true)
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at after_save."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        before_save
        before_create
        after_create
        after_rollback
        RUNS
      cwa.persisted?.should be_false
      cwa.new_record?.should be_true
      cwa.changed?.should be_false
      CallbackWithAbort.find("after_save").should be_nil
    end
  end

  context "when update" do
    it "rolls back if abort at before_validation" do
      CallbackWithAbort.new(abort_at: "before_validation", do_abort: false).save.should be_true
      cwa = CallbackWithAbort.find!("before_validation")
      cwa.do_abort = true
      cwa.history = IO::Memory.new

      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at before_validation."])
      cwa.history.to_s.strip.should eq <<-RUNS
        after_rollback
        RUNS
      cwa.persisted?.should be_true
      cwa.new_record?.should be_false
      cwa.do_abort.should be_true
      cwa.changed?.should be_true
      CallbackWithAbort.find!("before_validation").do_abort.should be_false
    end

    it "rolls back if abort at after_validation" do
      CallbackWithAbort.new(abort_at: "after_validation", do_abort: false).save.should be_true
      cwa = CallbackWithAbort.find!("after_validation")
      cwa.do_abort = true
      cwa.history = IO::Memory.new

      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at after_validation."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_rollback
        RUNS
      cwa.persisted?.should be_true
      cwa.new_record?.should be_false
      cwa.do_abort.should be_true
      cwa.changed?.should be_true
      CallbackWithAbort.find!("after_validation").do_abort.should be_false
    end

    it "doesn't run other callbacks if abort at before_save" do
      CallbackWithAbort.new(abort_at: "before_save", do_abort: false).save.should be_true
      cwa = CallbackWithAbort.find!("before_save")
      cwa.do_abort = true
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at before_save."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        after_rollback
        RUNS
      cwa.persisted?.should be_true
      cwa.new_record?.should be_false
      cwa.do_abort.should be_true
      cwa.changed?.should be_true
      CallbackWithAbort.find!("before_save").do_abort.should be_false
    end

    it "only runs before_save if abort at before_update" do
      CallbackWithAbort.new(abort_at: "before_update", do_abort: false).save.should be_true
      cwa = CallbackWithAbort.find!("before_update")
      cwa.do_abort = true
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at before_update."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        before_save
        after_rollback
        RUNS
      cwa.persisted?.should be_true
      cwa.new_record?.should be_false
      cwa.do_abort.should be_true
      cwa.changed?.should be_true
      CallbackWithAbort.find!("before_update").do_abort.should be_false
    end

    it "rolls back if abort at after_update" do
      CallbackWithAbort.new(abort_at: "after_update", do_abort: false).save.should be_true
      cwa = CallbackWithAbort.find!("after_update")
      cwa.do_abort = true
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at after_update."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        before_save
        before_update
        after_rollback
        RUNS
      cwa.persisted?.should be_true
      cwa.new_record?.should be_false
      cwa.do_abort.should be_true
      cwa.changed?.should be_true
      CallbackWithAbort.find!("after_update").do_abort.should be_false
    end

    it "rolls back if abort at after_save" do
      CallbackWithAbort.new(abort_at: "after_save", do_abort: false).save.should be_true
      cwa = CallbackWithAbort.find!("after_save")
      cwa.do_abort = true
      cwa.history = IO::Memory.new
      cwa.save.should be_false

      cwa.errors.map(&.to_s).should eq(["Aborted at after_save."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_validation
        after_validation
        before_save
        before_update
        after_update
        after_rollback
        RUNS
      cwa.persisted?.should be_true
      cwa.new_record?.should be_false
      cwa.do_abort.should be_true
      cwa.changed?.should be_true
      CallbackWithAbort.find!("after_save").do_abort.should be_false
    end
  end

  context "when destroy" do
    it "doesn't run other callbacks if abort at before_destroy" do
      CallbackWithAbort.new(abort_at: "before_destroy", do_abort: true).save
      cwa = CallbackWithAbort.find!("before_destroy")
      cwa.history = IO::Memory.new
      cwa.destroy

      cwa.errors.map(&.to_s).should eq(["Aborted at before_destroy."])
      cwa.history.to_s.strip.should eq("after_rollback")
      CallbackWithAbort.find("before_destroy").should be_a(CallbackWithAbort)
    end

    it "runs before_destroy and destroy successfully if abort at after_destory" do
      CallbackWithAbort.new(abort_at: "after_destroy", do_abort: true).save
      cwa = CallbackWithAbort.find!("after_destroy")
      cwa.history = IO::Memory.new
      cwa.destroy

      cwa.errors.map(&.to_s).should eq(["Aborted at after_destroy."])
      cwa.history.to_s.strip.should eq <<-RUNS
        before_destroy
        after_rollback
        RUNS
      CallbackWithAbort.find("after_destroy").should be_nil
    end
  end

  context "inside an explicit transaction" do
    it "rolls back only the aborted save" do
      kept = CallbackWithAbort.new(abort_at: "kept", do_abort: false)
      aborted = CallbackWithAbort.new(abort_at: "after_save", do_abort: true)
      aborted.history = IO::Memory.new

      CallbackWithAbort.transaction do
        kept.save.should be_true
        aborted.save.should be_false

        aborted.history.to_s.strip.should eq <<-RUNS
          before_validation
          after_validation
          before_save
          before_create
          after_create
          after_rollback
          RUNS
        aborted.persisted?.should be_false
        aborted.new_record?.should be_true
        CallbackWithAbort.find("kept").should be_a(CallbackWithAbort)
        CallbackWithAbort.find("after_save").should be_nil
      end

      CallbackWithAbort.find("kept").should be_a(CallbackWithAbort)
      CallbackWithAbort.find("after_save").should be_nil
    end
  end
end
