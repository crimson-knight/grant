require "./persistence_regression_helper"

describe "Grant pre-save dirty tracking T6" do
  it "tracks post-initialization assignments on new records with filters" do
    record = T6PersistenceRecord.new(name: "initial")

    record.changed?.should be_false
    record.name = "changed"

    record.changed?.should be_true
    record.will_save_change_to_attribute?("name").should be_true
    record.will_save_change_to_name?.should be_true
    record.will_save_change_to_name?(from: "initial", to: "changed").should be_true
    record.will_save_change_to_name?(from: "other").should be_false
    record.will_save_change_to_name?(to: "other").should be_false
  end
end
