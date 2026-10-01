require "./attribute_models"

describe "alias_attribute in queries" do
  before_each do
    AttrPost.clear
    AttrPost.create!(title: "b", views: 2)
    AttrPost.create!(title: "a", views: 1)
  end

  it "resolves the alias in Model.find_by and the relation find_by" do
    AttrPost.find_by(name: "a").try(&.views).should eq(1)
    AttrPost.find_by({"name" => "b"}).try(&.views).should eq(2)
    AttrPost.find_by!(name: "a").title.should eq("a")
    AttrPost.where(views: [1, 2]).find_by(name: "b").try(&.views).should eq(2)
    AttrPost.find_by(name: "missing").should be_nil
  end

  it "resolves the alias in order" do
    AttrPost.order(:name).select.map(&.title).should eq(["a", "b"])
    AttrPost.order(name: :desc).select.map(&.title).should eq(["b", "a"])
    AttrPost.order(:name, :desc).select.map(&.title).should eq(["b", "a"])
  end

  it "resolves the alias in pluck" do
    AttrPost.order(:title).pluck(:name).should eq([["a"], ["b"]])
    AttrPost.order(:title).pluck(:name, :views).should eq([["a", 1], ["b", 2]])
  end

  it "resolves the alias in select" do
    rows = AttrPost.select(:name).order(:name).select
    rows.map(&.title).should eq(["a", "b"])
  end

  it "resolves the alias in where(field, operator, value)" do
    AttrPost.where(:name, :eq, "a").select.map(&.views).should eq([1])
    AttrPost.where(:name, :like, "%b").count.should eq(1)
    AttrPost.where(:name, :in, ["a", "b"]).count.should eq(2)
  end

  it "delegates the dirty-control helpers" do
    post = AttrPost.create!(title: "before")
    post.name = "after"
    post.name_came_from_user?.should be_true
    post.will_save_change_to_name?.should be_true
    post.save!
    post.saved_change_to_name?.should be_true
    post.saved_change_to_name?(from: "before", to: "after").should be_true
    post.saved_change_to_name.should eq({"before", "after"})
    post.name_previously_was.should eq("before")
    post.name_previously_changed?.should be_true
    post.name_before_last_save.should eq("before")

    post.name = "again"
    post.restore_name!
    post.name.should eq("after")
    post.name_changed?.should be_false
  end
end
