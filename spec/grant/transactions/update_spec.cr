require "../../spec_helper"

describe "#update" do
  it "updates an object" do
    parent = Parent.new(name: "New Parent")
    parent.save!

    parent.update(name: "Other parent").should be_true
    parent.name.should eq "Other parent"

    Parent.find!(parent.id).name.should eq "Other parent"
  end

  it "allows setting a value to nil" do
    model = Teacher.create!(name: "New Parent")

    model.update(name: nil)

    model.name.should be_nil

    Teacher.find!(model.id).name.should be_nil
  end

  it "does not update an invalid object" do
    parent = Parent.new(name: "New Parent")
    parent.save!

    parent.update(name: "").should be_false
    parent.name.should eq ""

    Parent.find!(parent.id).name.should eq "New Parent"
  end

  context "when created_at is nil" do
    it "does not update created_at" do
      parent = Parent.new(name: "New Parent")
      parent.save!

      created_at = parent.created_at!.at_beginning_of_second

      # Simulating instantiating a new object with same ID
      new_parent = Parent.new(name: "New New Parent")
      new_parent.id = parent.id
      new_parent.new_record = false
      new_parent.updated_at = parent.updated_at
      new_parent.save!

      saved_parent = Parent.find!(parent.id)
      saved_parent.name.should eq "New New Parent"
      saved_parent.created_at.should eq created_at
      saved_parent.updated_at.should eq Time.utc.at_beginning_of_second
    end
  end

  context "when skip_timestamps is true" do
    it "does not update the updated_at field" do
      time = Time.utc(2023, 9, 1)
      parent = Parent.create(name: "New Parent")
      parent.updated_at = time
      parent.update({name: "Other Parent"}, skip_timestamps: true)

      Parent.find!(parent.id).updated_at.should eq time
    end
  end
end

describe "#update!" do
  it "updates an object" do
    parent = Parent.new(name: "New Parent")
    parent.save!

    parent.update!(name: "Other parent")
    parent.name.should eq "Other parent"

    Parent.find!(parent.id).name.should eq "Other parent"
  end

  it "does not update but raises an exception" do
    parent = Parent.new(name: "New Parent")
    parent.save!

    expect_raises(Grant::RecordNotSaved, "Parent") do
      parent.update!(name: "")
    end

    Parent.find!(parent.id).name.should eq "New Parent"
  end

  context "when skip_timestamps is true" do
    it "does not update the updated_at field" do
      time = Time.utc(2023, 9, 1)
      parent = Parent.create(name: "New Parent")
      parent.updated_at = time
      parent.update!({name: "Other Parent"}, skip_timestamps: true)

      Parent.find!(parent.id).updated_at.should eq time
    end
  end
end
