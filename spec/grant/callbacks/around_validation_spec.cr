require "../../spec_helper"

# around_validation wraps the entire validation phase (before_validation,
# the validators, and after_validation). If the around callback fails to call
# its continuation, validation is halted.

class AroundValidationModel < Grant::Base
  connection sqlite
  table around_validation_models

  column id : Int64, primary: true
  column name : String?

  property log = [] of String

  validates_presence_of :name

  around_validation :wrap_validation

  before_validation do
    log << "before_validation"
  end

  after_validation do
    log << "after_validation"
  end

  private def wrap_validation(block : Proc(Nil))
    log << "around_validation:before"
    block.call
    log << "around_validation:after"
  end
end

# Block-form around_validation
class AroundValidationBlockModel < Grant::Base
  connection sqlite
  table around_validation_block_models

  column id : Int64, primary: true
  column name : String?

  property log = [] of String

  validates_presence_of :name

  around_validation do |block|
    log << "block:before"
    block.call
    log << "block:after"
  end
end

# Halting around_validation: never call the continuation
class HaltingAroundValidationModel < Grant::Base
  connection sqlite
  table halting_around_validation_models

  column id : Int64, primary: true
  column name : String?

  property validators_ran = false

  validate :record_ran

  around_validation do |block|
    # intentionally never call block -> validators must not run
  end

  private def record_ran
    @validators_ran = true
    errors.add(:base, "should not appear")
  end
end

describe "around_validation callback" do
  it "wraps the validation phase in order" do
    m = AroundValidationModel.new
    m.name = "set"
    m.valid?.should be_true

    m.log.should eq([
      "around_validation:before",
      "before_validation",
      "after_validation",
      "around_validation:after",
    ])
  end

  it "still runs validators inside the wrapper (fails when invalid)" do
    m = AroundValidationModel.new
    m.name = nil
    m.valid?.should be_false
    m.errors.map(&.field.to_s).should contain("name")
    # the after hook still ran because the block was called
    m.log.should contain("around_validation:after")
  end

  it "supports the block form" do
    m = AroundValidationBlockModel.new
    m.name = "x"
    m.valid?.should be_true
    m.log.should eq(["block:before", "block:after"])
  end

  it "halts validation when the continuation is not called" do
    m = HaltingAroundValidationModel.new
    m.valid?
    m.validators_ran.should be_false
    m.errors.empty?.should be_true
  end
end
