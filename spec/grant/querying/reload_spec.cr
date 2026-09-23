require "../../spec_helper"

describe "#reload" do
  before_each do
    Parent.clear
  end

  it "reloads the record from the database" do
    parent = Parent.create(name: "Parent")

    Parent.find!(parent.id).update(name: "Other")

    parent.reload.name.should eq "Other"
  end

  it "refreshes the receiver in place and clears dirty state" do
    parent = Parent.create!(name: "Original")
    parent.name = "Unsaved change"
    parent.changed?.should be_true

    Parent.find!(parent.id).update!(name: "Changed elsewhere")

    reloaded = parent.reload

    reloaded.same?(parent).should be_true
    parent.name.should eq("Changed elsewhere")
    parent.changed?.should be_false
    parent.changes.should be_empty
    parent.previous_changes.should be_empty
  end

  it "raises an error if the record no longer exists" do
    parent = Parent.create(name: "Parent")
    parent.destroy

    expect_raises(Grant::Querying::NotFound) do
      parent.reload
    end
  end
end
