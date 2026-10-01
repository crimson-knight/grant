require "./dirty_family_models"

describe "Dirty control" do
  it "restores one attribute with restore_<attr>!" do
    post = F01Post.create!(title: "a", views: 1)
    post.title = "b"
    post.views = 2

    post.restore_title!
    post.title.should eq("a")
    post.title_changed?.should be_false
    post.views.should eq(2)
    post.views_changed?.should be_true

    post.title = "c"
    post.restore_attribute!("title")
    post.title.should eq("a")
    post.changed.should eq(["views"])
  end

  it "clears change information without touching values" do
    post = F01Post.create!(title: "a")
    post.update!(title: "b")
    post.title = "c"
    post.saved_changes.should_not be_empty

    post.clear_changes_information
    post.title.should eq("c")
    post.changed?.should be_false
    post.changes_to_save.should be_empty
    post.saved_changes.should be_empty
    post.saved_change_to_title?.should be_false
    post.title_in_database.should eq("c")

    # The new baseline is tracked from here.
    post.title = "d"
    post.title_was.should eq("c")
  end

  it "applies changes like a save does" do
    post = F01Post.create!(title: "a")
    post.title = "b"
    post.changes_applied

    post.changed?.should be_false
    post.title.should eq("b")
    post.saved_changes.should eq({"title" => {"a", "b"}})
    post.saved_change_to_title?(from: "a", to: "b").should be_true
    post.new_record?.should be_false

    post.title = "c"
    post.title_was.should eq("b")
  end

  it "clears the changes of named attributes and keeps their values" do
    post = F01Post.create!(title: "a", views: 1)
    post.title = "b"
    post.views = 2
    post.clear_attribute_changes(["title"])

    post.changed.should eq(["views"])
    post.title.should eq("b")
  end

  it "flags an attribute as changed with attribute_will_change!" do
    record = F01Tagged.new(title: "t", tags: ["a"])
    record.changed?.should be_false

    record.tags_will_change!
    record.changed?.should be_true
    record.attribute_changed?("tags").should be_true
    record.tags_change.should eq({["a"], ["a"]})

    # An in-place edit after the flag is reflected in the change.
    record.tags.not_nil! << "b"
    record.tags_change.should eq({["a"], ["a", "b"]})
    record.changes_to_save.should eq({"tags" => {["a"], ["a", "b"]}})
    record.tags_was.should eq(["a"])
  end

  it "stops watching a flagged attribute after restore" do
    record = F01Tagged.new(tags: ["a"])
    record.attribute_will_change!(:tags)
    record.tags.not_nil! << "b"
    record.restore_tags!
    record.tags.should eq(["a"])
    record.changed?.should be_false

    record.tags.not_nil! << "c"
    record.changed?.should be_false
  end

  it "records a flagged attribute as a saved change" do
    record = F01Tagged.new(title: "t", tags: ["a"])
    record.tags_will_change!
    record.tags.not_nil! << "b"
    record.changes_applied

    record.saved_change_to_tags.should eq({["a"], ["a", "b"]})
    record.changed?.should be_false
    record.tags.not_nil! << "c"
    record.changed?.should be_false
  end

  if CURRENT_ADAPTER == "pg"
    it "saves a flagged in-place edit" do
      record = F01Tagged.create!(title: "t", tags: ["a"])
      record.tags_will_change!
      record.tags.not_nil! << "b"
      record.save!

      record.saved_change_to_tags.should eq({["a"], ["a", "b"]})
      F01Tagged.find!(record.id).tags.should eq(["a", "b"])
    end
  end
end
