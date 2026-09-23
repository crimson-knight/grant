require "./luna_t4_spec_helper"

class NestedAttributesUpdateOnlyProfile < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table nested_attributes_update_only_profiles

  column id : Int64, primary: true
  column parent_id : Int64?
  column bio : String
end

class NestedAttributesUpdateOnlyParent < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table nested_attributes_update_only_parents

  column id : Int64, primary: true
  column label : String

  has_one :profile, class_name: NestedAttributesUpdateOnlyProfile, foreign_key: :parent_id
  accepts_nested_attributes_for profile : NestedAttributesUpdateOnlyProfile, update_only: true
  enable_nested_saves
end

describe "Grant::NestedAttributes update_only" do
  before_each do
    GrantLunaT4SpecHelper.ensure_test_connection
    NestedAttributesUpdateOnlyProfile.migrator.drop_and_create
    NestedAttributesUpdateOnlyParent.migrator.drop_and_create
  end

  it "updates the existing has_one record when the nested ID is omitted" do
    parent = NestedAttributesUpdateOnlyParent.create!(label: "parent")
    profile = NestedAttributesUpdateOnlyProfile.create!(parent_id: parent.id, bio: "old")

    parent.profile_attributes = {bio: "new"}
    parent.save.should be_true

    NestedAttributesUpdateOnlyProfile.find!(profile.id).bio.should eq("new")
  end

  it "adds an error when update_only has no existing association" do
    parent = NestedAttributesUpdateOnlyParent.create!(label: "parent without profile")

    parent.profile_attributes = {bio: "cannot be created"}
    parent.save.should be_true

    NestedAttributesUpdateOnlyProfile.find_by(parent_id: parent.id).should be_nil
    parent.errors.any? { |error| error.field.to_s == "profile" && error.message.to_s.includes?("not found") }.should be_true
  end
end
