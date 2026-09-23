require "./persistence_regression_helper"

describe "Grant mass assignment regression T6" do
  before_each do
    T6PersistenceRecord.clear
  end

  it "converts mass-assigned values and tracks valid updates" do
    record = T6PersistenceRecord.create!(name: "before", counter: 1)

    record.update(name: "after").should be_true

    record.previous_changes["name"].should eq({"before", "after"})
    record.saved_change_to_attribute?(:name).should be_true
    T6PersistenceRecord.find!(record.id).name.should eq("after")
  end

  it "reports invalid mass-assigned values as conversion errors" do
    record = T6PersistenceRecord.new(counter: "not-an-integer")

    record.errors.any?(Grant::ConversionError).should be_true
    record.persisted?.should be_false
    T6PersistenceRecord.count.should eq(0)
  end
end
