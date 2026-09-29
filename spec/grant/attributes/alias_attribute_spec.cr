require "./attribute_models"

describe "alias_attribute" do
  before_each { AttrPost.clear }

  it "generates the getter, setter and helpers" do
    post = AttrPost.create!(title: "Original")
    post.name.should eq("Original")
    post.name?.should eq("Original")
    post.name = "Renamed"
    post.title.should eq("Renamed")
    post.name_changed?.should be_true
    post.name_was.should eq("Original")
    post.name_change.should eq({"Original", "Renamed"})
    post.name_before_type_cast.should eq("Renamed")
  end

  it "is accepted by new and resolved by [] / has_attribute?" do
    post = AttrPost.new(name: "Via new")
    post.title.should eq("Via new")
    post["name"].should eq("Via new")
    AttrPost.has_column?("name").should be_true
    AttrPost.attribute_aliases.should eq({"name" => "title"})
  end

  it "is resolved in where(**args) and hash conditions" do
    AttrPost.create!(title: "a")
    AttrPost.create!(title: "b")

    AttrPost.where(name: "a").select.map(&.title).should eq(["a"])
    AttrPost.where({name: "b"}).select.map(&.title).should eq(["b"])
    AttrPost.where(name: ["a", "b"]).count.should eq(2)
    AttrPost.where(title: "a").where(name: "b").count.should eq(0)
  end
end
