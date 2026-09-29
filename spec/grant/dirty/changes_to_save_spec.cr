require "./dirty_family_models"

describe "Dirty tracking before save" do
  it "reports changes_to_save and has_changes_to_save?" do
    post = F01Post.create!(title: "a", views: 1)
    post.has_changes_to_save?.should be_false
    post.changes_to_save.should be_empty

    post.title = "b"
    post.has_changes_to_save?.should be_true
    post.changes_to_save.should eq({"title" => {"a", "b"}})
    post.changed_attribute_names_to_save.should eq(["title"])
  end

  it "reads attributes as the database holds them" do
    post = F01Post.create!(title: "a", views: 1)
    post.title = "b"

    post.attributes_in_database.should eq({"title" => "a"})
    post.attribute_in_database("title").should eq("a")
    post.title_in_database.should eq("a")
    post.attribute_in_database("views").should eq(1)
    post.views_in_database.should eq(1)
  end

  it "returns the pending change for one attribute" do
    post = F01Post.create!(title: "a")
    post.title = "b"

    post.attribute_change_to_be_saved("title").should eq({"a", "b"})
    post.title_change_to_be_saved.should eq({"a", "b"})
    post.attribute_change_to_be_saved("views").should be_nil
    post.views_change_to_be_saved.should be_nil
  end

  it "clears the pending changes after save" do
    post = F01Post.create!(title: "a")
    post.title = "b"
    post.save!
    post.has_changes_to_save?.should be_false
    post.attributes_in_database.should be_empty
  end

  it "does not allocate when checking has_changes_to_save?" do
    post = F01Post.create!(title: "a")
    post.title = "b"
    post.has_changes_to_save?.should be_true

    # Warm up, then compare GC bytes across many calls.
    post.has_changes_to_save?
    GC.collect
    before = GC.stats.total_bytes
    1000.times { post.has_changes_to_save? }
    (GC.stats.total_bytes - before).should eq(0)

    clean = F01Post.create!(title: "a")
    clean.has_changes_to_save?
    before = GC.stats.total_bytes
    1000.times { clean.has_changes_to_save? }
    (GC.stats.total_bytes - before).should eq(0)
  end
end
