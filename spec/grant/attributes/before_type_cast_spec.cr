require "./attribute_models"

describe "attribute_before_type_cast" do
  it "keeps the raw input when mass assignment converted it" do
    post = AttrPost.new(views: "42", published: "1")
    post.views.should eq(42)
    post.attribute_before_type_cast("views").should eq("42")
    post.views_before_type_cast.should eq("42")
    post.attribute_before_type_cast(:published).should eq("1")
  end

  it "keeps the raw input for assign_attributes" do
    post = AttrPost.new
    post.assign_attributes(views: "7")
    post.views_before_type_cast.should eq("7")
  end

  it "is not captured when the input already has the column type" do
    post = AttrPost.new(views: 42, title: "same")
    post.views_before_type_cast.should eq(42)
    post.instance_variable_get_for_spec.should be_nil
  end

  it "forgets the raw input once the typed setter runs" do
    post = AttrPost.new(views: "42")
    post.views = 43
    post.views_before_type_cast.should eq(43)
  end

  it "is never captured while loading rows" do
    post = AttrPost.create!(title: "Loaded", views: 5)
    loaded = AttrPost.find!(post.id)
    loaded.views_before_type_cast.should eq(5)
    loaded.instance_variable_get_for_spec.should be_nil
  end

  it "forgets the raw input on reload" do
    post = AttrPost.create!(title: "Reloaded", views: 5)
    post.assign_attributes(views: "7")
    post.views_before_type_cast.should eq("7")
    post.reload
    post.views.should eq(5)
    post.views_before_type_cast.should eq(5)
  end

  it "returns the converted database value for converter columns" do
    post = AttrPost.new(level: AttributeSpecModels::Level::Low)
    post.attribute_before_type_cast("level").should eq("Low")
  end

  it "raises for an unknown attribute" do
    expect_raises(Grant::UnknownAttributeError) { AttrPost.new.attribute_before_type_cast("nope") }
  end
end

class Grant::Base
  # Spec-only peek at whether any raw input was retained.
  def instance_variable_get_for_spec : Hash(String, Grant::Columns::Type)?
    @attributes_before_type_cast
  end
end
