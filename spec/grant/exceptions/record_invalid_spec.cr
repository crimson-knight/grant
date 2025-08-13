require "../../spec_helper"

describe Grant::RecordNotSaved do
  it "should have a message" do
    parent = Parent.new
    parent.save

    Grant::RecordNotSaved
      .new(Parent.name, parent)
      .message
      .should eq("Could not process Parent: Name cannot be blank")
  end

  it "should have a model" do
    parent = Parent.new
    parent.save

    Grant::RecordNotSaved
      .new(Parent.name, parent)
      .model
      .should eq(parent)
  end
end
