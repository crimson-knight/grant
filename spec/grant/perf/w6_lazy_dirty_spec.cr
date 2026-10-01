require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6LazyDirtyThing < Grant::Base
    connection {{ adapter_literal }}
    table w6_lazy_dirty_things

    column id : Int64, primary: true
    column title : String
    column views : Int32?
    column active : Bool = true
    timestamps
  end

  # An Array column is always watched for in-place edits, so this model keeps
  # a baseline for it. The column is not stored (SQLite has no array type), so
  # the model is only built in memory.
  class W6LazyWatchedThing < Grant::Base
    connection {{ adapter_literal }}
    table w6_lazy_watched_things

    column id : Int64, primary: true
    column title : String
    column tags : Array(String)?
  end
{% end %}

W6LazyDirtyThing.migrator.drop_and_create

describe "Lazy dirty tracking" do
  before_each do
    W6LazyDirtyThing.clear
  end

  it "allocates no dirty hashes for a hydrated record until a setter changes it" do
    created = W6LazyDirtyThing.create!(title: "a", views: 1)
    loaded = W6LazyDirtyThing.find!(created.id)

    loaded.__dirty_tracking_allocated?.should be_false
    loaded.changed?.should be_false
    loaded.changes.should be_empty
    loaded.changed.should be_empty
    loaded.previous_changes.should be_empty
    loaded.title_changed?.should be_false
    loaded.title_was.should eq("a")
    loaded.title_change.should be_nil
    loaded.attribute_changed?("views").should be_false
    loaded.attribute_was("views").should eq(1)
    loaded.__dirty_tracking_allocated?.should be_false
  end

  it "allocates none for a record built with mass assignment" do
    thing = W6LazyDirtyThing.new(title: "built", views: 5)

    thing.__dirty_tracking_allocated?.should be_false
    thing.title.should eq("built")
    thing.changed?.should be_false
    thing.changes.should be_empty
  end

  it "allocates none when a setter assigns the value the column already holds" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "same", views: 2).id)

    loaded.title = "same"
    loaded.views = 2

    loaded.changed?.should be_false
    loaded.__dirty_tracking_allocated?.should be_false
  end

  it "tracks a change from the first assignment, with the original kept" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "before", views: 1).id)

    loaded.title = "after"

    loaded.__dirty_tracking_allocated?.should be_true
    loaded.changed?.should be_true
    loaded.changed.should eq(["title"])
    loaded.changes.should eq({"title" => {"before", "after"}})
    loaded.title_was.should eq("before")
    loaded.title_change.should eq({"before", "after"})
    loaded.attribute_was("title").should eq("before")
    loaded.views_changed?.should be_false
  end

  it "keeps the first original across several assignments and forgets a change that is undone" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "one").id)

    loaded.title = "two"
    loaded.title = "three"
    loaded.changes.should eq({"title" => {"one", "three"}})

    loaded.title = "one"
    loaded.changed?.should be_false
    loaded.changes.should be_empty
  end

  it "records a change of a nilable column to and from nil" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "n", views: nil).id)

    loaded.views = 7
    loaded.changes.should eq({"views" => {nil, 7}})

    loaded.views = nil
    loaded.changed?.should be_false
  end

  it "treats the attributes given to new as the starting values, not changes" do
    thing = W6LazyDirtyThing.new(title: "start", views: 1)

    thing.title = "later"

    thing.changes.should eq({"title" => {"start", "later"}})
  end

  it "reports saved changes after a save and none after a clean one" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "x", views: 1).id)
    loaded.title = "y"
    loaded.save!

    loaded.changed?.should be_false
    loaded.saved_changes.has_key?("title").should be_true
    loaded.saved_change_to_attribute("title").should eq({"x", "y"})
    loaded.title_before_last_save.should eq("x")

    loaded.save!
    loaded.saved_changes.should be_empty
  end

  it "restores attributes from the captured originals" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "keep", views: 1).id)
    loaded.title = "drop"
    loaded.views = 9

    loaded.restore_attributes(["title"])

    loaded.title.should eq("keep")
    loaded.views.should eq(9)
    loaded.changed.should eq(["views"])
  end

  it "keeps in-place edits of an Array column visible, since those are always watched" do
    loaded = W6LazyWatchedThing.new(title: "t", tags: ["a"])

    loaded.changed?.should be_false
    loaded.tags.not_nil! << "b"
    loaded.changed?.should be_true
    loaded.changes["tags"][0].should eq(["a"])
  end

  it "rolls dirty state back with the transaction" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "orig").id)

    W6LazyDirtyThing.transaction do
      loaded.title = "temp"
      loaded.save!
      raise Grant::Transaction::Rollback.new
    end

    # The save's snapshot is taken with the pending change in place, so the
    # rollback brings that pending change back.
    loaded.title.should eq("temp")
    loaded.changes.should eq({"title" => {"orig", "temp"}})
    loaded.changed?.should be_true
  end

  it "does not build dirty hashes for the snapshot a save takes for rollback" do
    loaded = W6LazyDirtyThing.find!(W6LazyDirtyThing.create!(title: "snap").id)

    loaded.save!

    loaded.__dirty_tracking_allocated?.should be_false
  end
end
