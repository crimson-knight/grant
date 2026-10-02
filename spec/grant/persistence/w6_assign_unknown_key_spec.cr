require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6AssignOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6_assign_owners

    column id : Int64, primary: true
    column title : String?
    column views : Int32?
    alias_attribute :heading, :title
  end
{% end %}

W6AssignOwner.migrator.drop_and_create

describe "assign_attributes with an unknown key" do
  it "raises UnknownAttributeError naming the model and the key" do
    owner = W6AssignOwner.new
    error = expect_raises(Grant::UnknownAttributeError, /bogus/) do
      owner.assign_attributes(title: "x", bogus: 1)
    end
    error.attribute_name.should eq("bogus")
    error.model_name.should eq("W6AssignOwner")
  end

  it "assigns nothing when any key is unknown" do
    owner = W6AssignOwner.new
    expect_raises(Grant::UnknownAttributeError) { owner.assign_attributes({"title" => "x", "nope" => "y"}) }
    owner.title.should be_nil
  end

  it "raises through attributes= too" do
    owner = W6AssignOwner.new
    expect_raises(Grant::UnknownAttributeError) { owner.attributes = {"nope" => "y"} }
  end

  it "accepts columns, symbols and aliases" do
    owner = W6AssignOwner.new
    owner.assign_attributes(heading: "aliased", views: "3")
    owner.title.should eq("aliased")
    owner.views.should eq(3)
    owner.assign_attributes({:title => "sym"})
    owner.title.should eq("sym")
    owner.assignable_attribute?("heading").should be_true
    owner.assignable_attribute?("bogus").should be_false
  end
end
