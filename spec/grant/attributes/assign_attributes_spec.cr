require "./attribute_models"

describe "assign_attributes" do
  it "assigns from keyword arguments and returns the record" do
    post = AttrPost.new
    post.assign_attributes(title: "Hello", views: 2).should be(post)
    post.title.should eq("Hello")
    post.views.should eq(2)
  end

  it "assigns from string- and symbol-keyed hashes, converting values" do
    post = AttrPost.new
    post.assign_attributes({"title" => "Hash", "views" => "9"})
    post.title.should eq("Hash")
    post.views.should eq(9)

    post.assign_attributes({:views => "10"})
    post.views.should eq(10)
  end

  it "assigns through attributes=" do
    post = AttrPost.new
    post.attributes = {"title" => "Writer", "published" => "true"}
    post.title.should eq("Writer")
    post.published.should be_true
  end

  it "records conversion errors and tracks changes" do
    post = AttrPost.create!(title: "Before")
    post.assign_attributes(title: "After", views: "many")
    post.title_changed?.should be_true
    post.errors.map(&.field.to_s).should contain("views")
  end

  it "resolves aliases" do
    post = AttrPost.new
    post.assign_attributes(name: "Aliased")
    post.title.should eq("Aliased")
  end
end
