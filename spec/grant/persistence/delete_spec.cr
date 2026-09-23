require "./persistence_regression_helper"

describe "Grant instance delete T6" do
  before_each do
    T6DeleteRecord.clear
  end

  it "deletes without callbacks and marks the instance destroyed" do
    record = T6DeleteRecord.create!(name: "delete me")

    record.delete.same?(record).should be_true

    T6DeleteRecord.find(record.id).should be_nil
    record.destroyed?.should be_true
    record.persisted?.should be_false
    record.has_destroy_callback_run.should be_false
  end

  it "restores the instance state when its delete is rolled back" do
    record = T6DeleteRecord.create!(name: "restore me")

    T6DeleteRecord.transaction do
      record.delete
      record.destroyed?.should be_true
      raise Grant::Transaction::Rollback.new
    end

    record.destroyed?.should be_false
    record.persisted?.should be_true
    T6DeleteRecord.find!(record.id).name.should eq("restore me")
  end
end
