require "./attribute_models"

describe "model reflection" do
  it "describes columns as a constant array" do
    columns = AttrPost.columns
    columns.map(&.name).should eq(AttrPost.attribute_names)
    columns.should be(AttrPost.columns)

    id = AttrPost.columns_hash["id"]
    id.crystal_type.should eq("Int64")
    id.primary?.should be_true
    id.nilable?.should be_false

    title = AttrPost.columns_hash["title"]
    title.crystal_type.should eq("String")
    title.nilable?.should be_true
    title.converter.should be_nil

    AttrPost.columns_hash["level"].converter.should eq("Grant::Converters::Enum(AttributeSpecModels::Level, String)")
  end

  it "maps attributes to type names" do
    AttrPost.type_for_attribute("views").should eq("Int32")
    AttrPost.type_for_attribute(:created_at).should eq("Time")
    AttrPost.type_for_attribute("name").should eq("String")
    AttrPost.type_for_attribute("nope").should be_nil
    AttrPost.attribute_types["published"].should eq("Bool")
    AttrPost.attribute_types.size.should eq(AttrPost.columns.size)
  end

  it "reports the primary key and content columns" do
    AttrPost.primary_key.should eq("id")
    AttrPost.content_columns.map(&.name).should eq(["title", "views", "published", "level", "created_at", "updated_at"])
  end

  it "accepts reset_column_information as a no-op" do
    AttrPost.reset_column_information
    AttrPost.columns.size.should eq(8)
  end
end
