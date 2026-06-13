require "../../spec_helper"

# Proc/lambda if:/unless: conditions on lifecycle callbacks (not just Symbols).

class ProcCallbackModel < Grant::Base
  connection sqlite
  table proc_callback_models

  column id : Int64, primary: true
  column name : String?
  column enabled : Bool = true

  property log = [] of String

  # Proc condition gating a before_save callback
  before_save :log_enabled, if: ->(r : ProcCallbackModel) { !!r.enabled }

  # Proc unless condition gating an after_save callback
  after_save :log_after, unless: ->(r : ProcCallbackModel) { !!r.skip_after }

  property skip_after = false

  private def log_enabled
    log << "before_save:enabled"
  end

  private def log_after
    log << "after_save"
  end
end

# Symbol-form conditions (previously implemented but untested — the
# NamedTuple/NamedTupleLiteral macro fix is what makes these actually run).
class SymbolCallbackModel < Grant::Base
  connection sqlite
  table symbol_callback_models

  column id : Int64, primary: true
  column name : String?
  column active : Bool = true

  property log = [] of String

  before_save :log_active, if: :active?
  after_save :log_done, unless: :inactive?

  def active?
    !!active
  end

  def inactive?
    !active
  end

  private def log_active
    log << "before_save:active"
  end

  private def log_done
    log << "after_save:done"
  end
end

# Proc condition on an around callback
class ProcAroundCallbackModel < Grant::Base
  connection sqlite
  table proc_around_callback_models

  column id : Int64, primary: true
  column name : String?
  column wrap : Bool = true

  property log = [] of String

  around_save :wrap_save, if: ->(r : ProcAroundCallbackModel) { !!r.wrap }

  private def wrap_save(block : Proc(Nil))
    log << "around:before"
    block.call
    log << "around:after"
  end
end

describe "Proc/lambda conditions on lifecycle callbacks" do
  before_all do
    ProcCallbackModel.migrator.drop_and_create
    ProcAroundCallbackModel.migrator.drop_and_create
    SymbolCallbackModel.migrator.drop_and_create
  end

  before_each do
    ProcCallbackModel.clear
    ProcAroundCallbackModel.clear
    SymbolCallbackModel.clear
  end

  describe "Symbol-form conditions on lifecycle callbacks" do
    it "runs before_save when the if: method is truthy" do
      m = SymbolCallbackModel.new
      m.name = "x"
      m.active = true
      m.save
      m.log.should contain("before_save:active")
      m.log.should contain("after_save:done")
    end

    it "skips before_save when the if: method is falsey" do
      m = SymbolCallbackModel.new
      m.name = "x"
      m.active = false
      m.save
      m.log.should_not contain("before_save:active")
      # unless: :inactive? is now truthy -> after_save skipped
      m.log.should_not contain("after_save:done")
    end
  end

  describe "if: proc on before_save" do
    it "runs the callback when the proc is truthy" do
      m = ProcCallbackModel.new
      m.name = "x"
      m.enabled = true
      m.save
      m.log.should contain("before_save:enabled")
    end

    it "skips the callback when the proc is falsey" do
      m = ProcCallbackModel.new
      m.name = "x"
      m.enabled = false
      m.save
      m.log.should_not contain("before_save:enabled")
    end
  end

  describe "unless: proc on after_save" do
    it "runs when the proc is falsey" do
      m = ProcCallbackModel.new
      m.name = "x"
      m.skip_after = false
      m.save
      m.log.should contain("after_save")
    end

    it "skips when the proc is truthy" do
      m = ProcCallbackModel.new
      m.name = "x"
      m.skip_after = true
      m.save
      m.log.should_not contain("after_save")
    end
  end

  describe "if: proc on around_save" do
    it "wraps when the proc is truthy" do
      m = ProcAroundCallbackModel.new
      m.name = "x"
      m.wrap = true
      m.save
      m.log.should eq(["around:before", "around:after"])
    end

    it "does not wrap when the proc is falsey (still saves)" do
      m = ProcAroundCallbackModel.new
      m.name = "x"
      m.wrap = false
      result = m.save
      result.should be_true
      m.log.should be_empty
    end
  end
end
