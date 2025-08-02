require "../../spec_helper"

class CallbackTest < Granite::Base
  connection sqlite
  table callback_tests
  
  column id : Int64, primary: true
  column name : String?
  timestamps
  
  property callback_history = [] of String
  
  after_initialize do
    callback_history << "after_initialize"
  end
  
  after_find do
    callback_history << "after_find"
  end
  
  before_validation do
    callback_history << "before_validation"
  end
  
  after_validation do
    callback_history << "after_validation"
  end
  
  before_save do
    callback_history << "before_save"
  end
  
  after_save do
    callback_history << "after_save"
  end
  
  before_create do
    callback_history << "before_create"
  end
  
  after_create do
    callback_history << "after_create"
  end
  
  before_update do
    callback_history << "before_update"
  end
  
  after_update do
    callback_history << "after_update"
  end
  
  before_destroy do
    callback_history << "before_destroy"
  end
  
  after_destroy do
    callback_history << "after_destroy"
  end
  
  after_touch do
    callback_history << "after_touch"
  end
  
  after_commit do
    callback_history << "after_commit"
  end
  
  after_rollback do
    callback_history << "after_rollback"
  end
  
  after_create_commit do
    callback_history << "after_create_commit"
  end
  
  after_update_commit do
    callback_history << "after_update_commit"
  end
  
  after_destroy_commit do
    callback_history << "after_destroy_commit"
  end
end

# Model for testing rollback callbacks
class FailingCallbackTest < Granite::Base
  connection sqlite
  table failing_callback_tests
  
  column id : Int64, primary: true
  column name : String?
  
  property callback_history = [] of String
  
  before_save do
    callback_history << "before_save"
    abort!("Force failure")
  end
  
  after_rollback do
    callback_history << "after_rollback"
  end
end

describe "Granite::Callbacks::Lifecycle" do
  before_all do
    CallbackTest.migrator.drop_and_create
    FailingCallbackTest.migrator.drop_and_create
  end
  
  describe "after_initialize" do
    it "runs after new" do
      model = CallbackTest.new
      model.callback_history.should contain("after_initialize")
    end
    
    it "runs after new with attributes" do
      model = CallbackTest.new(name: "Test")
      model.callback_history.should contain("after_initialize")
    end
  end
  
  describe "after_find" do
    it "runs when loading from database" do
      model = CallbackTest.new(name: "Test")
      model.save
      
      found = CallbackTest.find!(model.id)
      found.callback_history.should contain("after_find")
    end
  end
  
  describe "validation callbacks" do
    it "runs before and after validation" do
      model = CallbackTest.new(name: "Test")
      model.valid?
      
      model.callback_history.should contain("before_validation")
      model.callback_history.should contain("after_validation")
      
      # Check order
      before_index = model.callback_history.index("before_validation").not_nil!
      after_index = model.callback_history.index("after_validation").not_nil!
      before_index.should be < after_index
    end
  end
  
  describe "create callbacks" do
    it "runs callbacks in correct order on create" do
      model = CallbackTest.new(name: "Test")
      model.save
      
      expected_order = [
        "after_initialize",
        "before_validation",
        "after_validation",
        "before_save",
        "before_create",
        "after_create",
        "after_save",
        "after_create_commit",
        "after_commit"
      ]
      
      # Filter to only the callbacks we expect
      actual = model.callback_history.select { |cb| expected_order.includes?(cb) }
      actual.should eq(expected_order)
    end
  end
  
  describe "update callbacks" do
    it "runs callbacks in correct order on update" do
      model = CallbackTest.new(name: "Test")
      model.save
      model.callback_history.clear
      
      model.name = "Updated"
      model.save
      
      expected_order = [
        "before_validation",
        "after_validation",
        "before_save",
        "before_update",
        "after_update",
        "after_save",
        "after_update_commit",
        "after_commit"
      ]
      
      actual = model.callback_history.select { |cb| expected_order.includes?(cb) }
      actual.should eq(expected_order)
    end
  end
  
  describe "destroy callbacks" do
    it "runs callbacks in correct order on destroy" do
      model = CallbackTest.new(name: "Test")
      model.save
      model.callback_history.clear
      
      model.destroy
      
      expected_order = [
        "before_destroy",
        "after_destroy",
        "after_destroy_commit",
        "after_commit"
      ]
      
      actual = model.callback_history.select { |cb| expected_order.includes?(cb) }
      actual.should eq(expected_order)
    end
  end
  
  describe "after_touch" do
    it "runs after touch" do
      model = CallbackTest.new(name: "Test")
      model.save
      model.callback_history.clear
      
      model.touch
      
      model.callback_history.should contain("after_touch")
    end
  end
  
  describe "rollback callbacks" do
    it "runs after_rollback on save failure" do
      model = FailingCallbackTest.new(name: "Test")
      model.save
      
      model.callback_history.should contain("before_save")
      model.callback_history.should contain("after_rollback")
    end
  end
end