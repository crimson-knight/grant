require "./dirty_family_models"

describe "Opt-in in-place mutation detection" do
  it "does not detect an Array edit on a model that has not opted in" do
    record = F01Tagged.new(tags: ["a"])
    record.tags.not_nil! << "b"
    record.changed?.should be_false
    record.tags_changed?.should be_false
    F01Tagged.mutation_detected_attributes.should be_empty
  end

  it "detects an Array edit on a watched column" do
    record = F01Watched.new(title: "t", tags: ["a"])
    record.changed?.should be_false

    record.tags.not_nil! << "b"
    record.changed?.should be_true
    record.tags_changed?.should be_true
    record.tags_was.should eq(["a"])
    record.tags_change.should eq({["a"], ["a", "b"]})
    record.changes_to_save.should eq({"tags" => {["a"], ["a", "b"]}})
    record.has_changes_to_save?.should be_true
    record.attribute_changed?("tags").should be_true
  end

  it "is no longer dirty when the edit is undone" do
    record = F01Watched.new(tags: ["a"])
    record.tags.not_nil! << "b"
    record.changed?.should be_true
    record.tags.not_nil!.pop
    record.changed?.should be_false
  end

  it "only watches the columns it was given" do
    F01WatchedNamed.mutation_detected_attributes.should eq(["tags"])

    record = F01WatchedNamed.new(tags: ["a"], labels: ["x"])
    record.labels.not_nil! << "y"
    record.changed?.should be_false
    record.tags.not_nil! << "b"
    record.changed.should eq(["tags"])
  end

  it "never watches scalar or String columns" do
    watched = F01Watched.mutation_detected_attributes
    watched.should eq(["tags"])
    F01Prefs.mutation_detected_attributes.should eq(["_serialized_prefs"])
    watched.should_not contain("id")
    watched.should_not contain("views")
    watched.should_not contain("title")
    F01Post.mutation_detected_attributes.should be_empty
  end

  it "keeps the baseline as a copy, so the edit cannot rewrite it" do
    record = F01Watched.new(tags: ["a"])
    record.tags.not_nil! << "b"
    record.tags_in_database.should eq(["a"])
    record.attributes_in_database.should eq({"tags" => ["a"]})
  end

  it "restores an edited Array to a copy of the original" do
    record = F01Watched.new(tags: ["a"])
    record.tags.not_nil! << "b"
    record.restore_tags!
    record.tags.should eq(["a"])
    record.changed?.should be_false

    record.tags.not_nil! << "c"
    record.tags_was.should eq(["a"])
  end

  it "reports an edit as a saved change after changes_applied" do
    record = F01Watched.new(tags: ["a"])
    record.tags.not_nil! << "b"
    record.changes_applied

    record.saved_change_to_tags.should eq({["a"], ["a", "b"]})
    record.changed?.should be_false
    record.tags.not_nil! << "c"
    record.tags_was.should eq(["a", "b"])
  end

  describe "serialized columns" do
    it "detects an in-place edit of the serialized object" do
      record = F01Prefs.new(title: "t")
      record.prefs = F01Settings.new(theme: "light")
      record.save!
      record.changed?.should be_false

      record.prefs.not_nil!.theme = "dark"
      record.changed?.should be_true
      record.changed.should eq(["_serialized_prefs"])

      record.prefs.not_nil!.theme = "light"
      record.changed?.should be_false
    end

    it "persists an in-place edit and records it as a saved change" do
      record = F01Prefs.new(title: "t")
      record.prefs = F01Settings.new
      record.save!
      record.prefs.not_nil!.items << "one"
      record.save!

      record.saved_change_to_attribute?("_serialized_prefs").should be_true
      record.changed?.should be_false
      F01Prefs.find!(record.id).prefs.not_nil!.items.should eq(["one"])
    end

    it "ignores the same edit when the model has not opted in" do
      record = F01PlainPrefs.new
      record.prefs = F01Settings.new
      record.save!
      record.prefs.not_nil!.theme = "dark"
      record.changed?.should be_false
    end
  end

  if CURRENT_ADAPTER == "pg"
    it "persists an Array edit" do
      record = F01Watched.create!(title: "t", tags: ["a"])
      record.tags.not_nil! << "b"
      record.save!

      record.saved_change_to_tags.should eq({["a"], ["a", "b"]})
      F01Watched.find!(record.id).tags.should eq(["a", "b"])
    end

    it "still detects an in-place edit after update_columns" do
      record = F01Watched.create!(title: "t", tags: ["a"])
      record.update_columns(tags: ["a", "b"])
      record.changed?.should be_false

      record.tags.not_nil! << "c"
      record.changed?.should be_true
      record.tags_change.should eq({["a", "b"], ["a", "b", "c"]})
    end
  end
end
