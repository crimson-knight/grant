require "../../spec_helper"

describe "around callbacks" do
  before_all do
    AroundCallbackModel.migrator.drop_and_create
    HaltingAroundModel.migrator.drop_and_create
    MultiAroundModel.migrator.drop_and_create
    MethodAroundModel.migrator.drop_and_create
  end

  before_each do
    AroundCallbackModel.clear
    HaltingAroundModel.clear
    MultiAroundModel.clear
    MethodAroundModel.clear
  end

  describe "around_save" do
    it "wraps the save operation with before/after behavior" do
      record = AroundCallbackModel.new
      record.name = "test"
      record.save

      record.log.should contain("around_save:before")
      record.log.should contain("around_save:after")
      # Verify order: around_save:before comes before around_save:after
      before_idx = record.log.index("around_save:before").not_nil!
      after_idx = record.log.index("around_save:after").not_nil!
      before_idx.should be < after_idx
    end

    it "actually persists the record when block is called" do
      record = AroundCallbackModel.new
      record.name = "persisted"
      result = record.save
      result.should be_true
      AroundCallbackModel.where(name: "persisted").first.should be_a(AroundCallbackModel)
    end
  end

  describe "around_create" do
    it "wraps the create operation" do
      record = AroundCallbackModel.new
      record.name = "test_create"
      record.save

      record.log.should contain("around_create:before")
      record.log.should contain("around_create:after")
    end

    it "does not run around_create on update" do
      record = AroundCallbackModel.new
      record.name = "update_test"
      record.save
      record.log.clear

      record.name = "update_test_modified"
      record.save

      record.log.should_not contain("around_create:before")
      record.log.should_not contain("around_create:after")
    end
  end

  describe "around_update" do
    it "wraps the update operation" do
      AroundCallbackModel.new.tap { |r| r.name = "to_update"; r.save }
      record = AroundCallbackModel.where(name: "to_update").first!
      record.log.clear

      record.name = "to_update_v2"
      record.save

      record.log.should contain("around_update:before")
      record.log.should contain("around_update:after")
    end

    it "does not run around_update on create" do
      record = AroundCallbackModel.new
      record.name = "create_only"
      record.save

      record.log.should_not contain("around_update:before")
      record.log.should_not contain("around_update:after")
    end
  end

  describe "around_destroy" do
    it "wraps the destroy operation" do
      AroundCallbackModel.new.tap { |r| r.name = "to_destroy"; r.save }
      record = AroundCallbackModel.where(name: "to_destroy").first!
      record.log.clear

      record.destroy

      record.log.should contain("around_destroy:before")
      record.log.should contain("around_destroy:after")
    end

    it "actually destroys the record when block is called" do
      AroundCallbackModel.new.tap { |r| r.name = "will_die"; r.save }
      record = AroundCallbackModel.where(name: "will_die").first!
      result = record.destroy
      result.should be_true
      AroundCallbackModel.where(name: "will_die").first?.should be_nil
    end
  end

  describe "halting" do
    it "halts save when around_save does not call block" do
      record = HaltingAroundModel.new
      record.name = "halt_save"
      record.halt_around_save = true
      result = record.save
      result.should be_false
      HaltingAroundModel.where(name: "halt_save").first?.should be_nil
    end

    it "halts create when around_create does not call block" do
      record = HaltingAroundModel.new
      record.name = "halt_create"
      record.halt_around_create = true
      result = record.save
      result.should be_false
      HaltingAroundModel.where(name: "halt_create").first?.should be_nil
    end

    it "halts destroy when around_destroy does not call block" do
      HaltingAroundModel.new.tap { |r| r.name = "no_destroy"; r.save }
      record = HaltingAroundModel.where(name: "no_destroy").first!
      record.halt_around_destroy = true
      result = record.destroy
      result.should be_false
      # Record should still exist
      HaltingAroundModel.where(name: "no_destroy").first?.should be_a(HaltingAroundModel)
    end

    it "does not run after_save when around_save halts" do
      record = HaltingAroundModel.new
      record.name = "halt_no_after"
      record.halt_around_save = true
      record.save

      record.log.should contain("around_save:halted")
      record.log.should_not contain("after_save")
    end
  end

  describe "multiple around callbacks" do
    it "nests callbacks in registration order (first = outermost)" do
      record = MultiAroundModel.new
      record.name = "multi"
      record.save

      # First registered wraps second registered wraps operation
      record.log.should contain("outer:before")
      record.log.should contain("inner:before")
      record.log.should contain("inner:after")
      record.log.should contain("outer:after")

      # Verify nesting order
      outer_before = record.log.index("outer:before").not_nil!
      inner_before = record.log.index("inner:before").not_nil!
      inner_after = record.log.index("inner:after").not_nil!
      outer_after = record.log.index("outer:after").not_nil!

      outer_before.should be < inner_before
      inner_before.should be < inner_after
      inner_after.should be < outer_after
    end
  end

  describe "method-based around callbacks" do
    it "uses a named method as around callback" do
      record = MethodAroundModel.new
      record.name = "method_cb"
      record.save

      record.log.should contain("method_around:before")
      record.log.should contain("method_around:after")
    end
  end
end

# ============================================================
# Test Models
# ============================================================

# Basic model with around callbacks using blocks
class AroundCallbackModel < Grant::Base
  connection sqlite
  table around_callback_models

  column id : Int64, primary: true
  column name : String?

  property log : Array(String) = [] of String

  around_save do |block|
    log << "around_save:before"
    block.call
    log << "around_save:after"
  end

  around_create do |block|
    log << "around_create:before"
    block.call
    log << "around_create:after"
  end

  around_update do |block|
    log << "around_update:before"
    block.call
    log << "around_update:after"
  end

  around_destroy do |block|
    log << "around_destroy:before"
    block.call
    log << "around_destroy:after"
  end
end

# Model that can conditionally halt around callbacks
class HaltingAroundModel < Grant::Base
  connection sqlite
  table halting_around_models

  column id : Int64, primary: true
  column name : String?

  property log : Array(String) = [] of String
  property halt_around_save : Bool = false
  property halt_around_create : Bool = false
  property halt_around_destroy : Bool = false

  around_save do |block|
    if halt_around_save
      log << "around_save:halted"
      # Not calling block.call — operation should be halted
    else
      log << "around_save:before"
      block.call
      log << "around_save:after"
    end
  end

  around_create do |block|
    if halt_around_create
      log << "around_create:halted"
    else
      block.call
    end
  end

  around_destroy do |block|
    if halt_around_destroy
      log << "around_destroy:halted"
    else
      block.call
    end
  end

  after_save do
    log << "after_save"
  end
end

# Model with multiple around_save callbacks to test nesting
class MultiAroundModel < Grant::Base
  connection sqlite
  table multi_around_models

  column id : Int64, primary: true
  column name : String?

  property log : Array(String) = [] of String

  # First registered = outermost wrapper
  around_save do |block|
    log << "outer:before"
    block.call
    log << "outer:after"
  end

  # Second registered = inner wrapper
  around_save do |block|
    log << "inner:before"
    block.call
    log << "inner:after"
  end
end

# Model with method-based around callback
class MethodAroundModel < Grant::Base
  connection sqlite
  table method_around_models

  column id : Int64, primary: true
  column name : String?

  property log : Array(String) = [] of String

  around_save :wrap_in_logging

  private def wrap_in_logging(block : Proc(Nil))
    log << "method_around:before"
    block.call
    log << "method_around:after"
  end
end
