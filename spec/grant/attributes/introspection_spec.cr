require "./attribute_models"

describe "attribute introspection" do
  it "lists attribute and column names on the class and the record" do
    AttrPost.attribute_names.should eq(["id", "title", "views", "published", "level", "author_id", "created_at", "updated_at"])
    AttrPost.column_names.should eq(AttrPost.attribute_names)
    AttrPost.new.attribute_names.should eq(AttrPost.attribute_names)
  end

  it "returns every attribute with converters applied" do
    post = AttrPost.new(title: "Hello", views: 3, level: AttributeSpecModels::Level::High)
    attributes = post.attributes

    attributes.keys.should eq(AttrPost.attribute_names)
    attributes["title"].should eq("Hello")
    attributes["views"].should eq(3)
    attributes["level"].should eq("High")
    attributes["id"].should be_nil
  end

  it "answers has_attribute? for columns, aliases and strangers" do
    post = AttrPost.new
    post.has_attribute?("title").should be_true
    post.has_attribute?(:views).should be_true
    post.has_attribute?("name").should be_true
    post.has_attribute?("nope").should be_false
  end

  it "answers attribute_present? like ActiveRecord" do
    post = AttrPost.new(title: "", views: 0)
    post.attribute_present?("title").should be_false
    post.attribute_present?("published").should be_false
    post.attribute_present?("views").should be_true
    post.title = "x"
    post.attribute_present?(:title).should be_true
    expect_raises(Grant::UnknownAttributeError) { post.attribute_present?("nope") }
  end

  it "reads and writes by name with [] and []=" do
    post = AttrPost.new(title: "Hello")
    post["title"].should eq("Hello")
    post[:title].should eq("Hello")
    post["name"].should eq("Hello")

    post["views"] = 7
    post.views.should eq(7)
    post.views_changed?.should be_true

    expect_raises(Grant::UnknownAttributeError) { post["nope"] }
    expect_raises(Grant::UnknownAttributeError) { post["nope"] = 1 }
  end

  it "slices and collects values in the requested order" do
    post = AttrPost.new(title: "Hello", views: 3)
    post.slice("title", :views).should eq({"title" => "Hello", "views" => 3})
    post.values_at("views", "title").should eq([3, "Hello"])
  end

  it "reflects a persisted record" do
    post = AttrPost.create!(title: "Saved", views: 1)
    loaded = AttrPost.find!(post.id)
    loaded.attributes["title"].should eq("Saved")
    loaded.slice("id").should eq({"id" => post.id})
  end
end
