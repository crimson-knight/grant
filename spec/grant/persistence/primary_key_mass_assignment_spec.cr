require "./persistence_regression_helper"

describe "Grant primary key mass assignment regression T6" do
  before_each do
    T6MassAssignmentPrimaryKeyRecord.clear
  end

  it "preserves an explicitly assigned auto-generated primary key" do
    record = T6MassAssignmentPrimaryKeyRecord.create!(id: 501_i64, name: "explicit")

    record.id.should eq(501_i64)
    T6MassAssignmentPrimaryKeyRecord.find!(501_i64).name.should eq("explicit")
  end
end
