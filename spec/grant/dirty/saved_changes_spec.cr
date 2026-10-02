require "./dirty_family_models"

describe "Saved-change per-attribute API" do
  it "reports saved_change_to_<attr>? with from: and to: filters" do
    post = F01Post.create!(title: "first", views: 1)
    post.saved_change_to_title?.should be_true # creation is a change from nil

    post.title = "second"
    post.saved_change_to_title?.should be_true # still the create's change until saved
    post.save!

    post.saved_change_to_title?.should be_true
    post.saved_change_to_title?(from: "first").should be_true
    post.saved_change_to_title?(to: "second").should be_true
    post.saved_change_to_title?(from: "first", to: "second").should be_true
    post.saved_change_to_title?(from: "nope").should be_false
    post.saved_change_to_title?(to: "nope").should be_false
    post.saved_change_to_views?.should be_false
  end

  it "returns the change as a tuple" do
    post = F01Post.create!(title: "a")
    post.title = "b"
    post.save!

    post.saved_change_to_title.should eq({"a", "b"})
    post.saved_change_to_attribute("title").should eq({"a", "b"})
    post.saved_change_to_attribute(:title).should eq({"a", "b"})
    post.saved_change_to_views.should be_nil
    post.saved_change_to_attribute("views").should be_nil
  end

  it "exposes previously_was and previously_changed?" do
    post = F01Post.create!(title: "a", views: 5)
    post.title = "b"
    post.save!

    post.title_previously_was.should eq("a")
    post.attribute_previously_was("title").should eq("a")
    post.title_previously_changed?.should be_true
    post.title_previously_changed?(from: "a", to: "b").should be_true
    post.title_previously_changed?(from: "b").should be_false
    post.attribute_previously_changed?("title", to: "b").should be_true

    # An unchanged attribute reports its current value.
    post.views_previously_was.should eq(5)
    post.views_previously_changed?.should be_false
  end

  it "matches a nil from: filter" do
    post = F01Post.new(title: "x")
    post.save!
    post.body = "text"
    post.save!

    post.saved_change_to_body?(from: nil).should be_true
    post.saved_change_to_body?(from: nil, to: "text").should be_true
  end

  it "is usable from an after_save callback view of the record" do
    post = F01Post.create!(title: "a")
    post.update!(title: "b")
    post.saved_change_to_title?(from: "a", to: "b").should be_true
    post.update!(views: 3)
    post.saved_change_to_title?.should be_false
    post.saved_change_to_views?(to: 3).should be_true
  end
end
