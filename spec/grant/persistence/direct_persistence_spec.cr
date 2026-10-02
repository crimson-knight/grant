require "./persistence_regression_helper"

describe "Grant direct persistence regressions T6" do
  before_each do
    T6PersistenceRecord.clear
    T6ReadonlyRecord.clear
    T6TouchRecord.clear
  end

  it "updates a primary key using its original value in the where clause" do
    record = T6PersistenceRecord.create!(name: "primary key")
    old_id = record.id.not_nil!
    new_id = old_id + 100_000_000

    record.update_columns(id: new_id).should be_true

    record.id.should eq(new_id)
    T6PersistenceRecord.find(old_id).should be_nil
    T6PersistenceRecord.find!(new_id).name.should eq("primary key")
  end

  it "clears only directly updated columns from dirty tracking" do
    record = T6PersistenceRecord.create!(name: "original", note: "saved")
    record.name = "direct"
    record.note = "pending"

    record.update_columns(name: "direct").should be_true

    record.name_changed?.should be_false
    record.note_changed?.should be_true
    record.changed.should eq(["note"])
    T6PersistenceRecord.find!(record.id).name.should eq("direct")
    T6PersistenceRecord.find!(record.id).note.should eq("saved")
  end

  it "rejects update_columns for read-only attributes before changing the record" do
    record = T6ReadonlyRecord.create!(slug: "original")

    expect_raises(Grant::ReadOnlyRecordError) do
      record.update_columns(slug: "changed")
    end

    record.slug.should eq("original")
    T6ReadonlyRecord.find!(record.id).slug.should eq("original")
  end

  it "increments only the requested column and leaves other changes pending" do
    record = T6TouchRecord.create!(name: "saved", note: "old note", counter: 0)
    record.list_of_callback_events.clear
    record.note = "unsaved note"

    record.increment!(:counter)

    fresh = T6TouchRecord.find!(record.id)
    fresh.counter.should eq(1)
    fresh.note.should eq("old note")
    record.counter.should eq(1)
    record.note.should eq("unsaved note")
    record.counter_changed?.should be_false
    record.note_changed?.should be_true
    record.list_of_callback_events.should be_empty
  end

  it "touches timestamps without saving unrelated changes or running save callbacks" do
    record = T6TouchRecord.new(name: "saved", note: "old note")
    record.updated_at = Time.utc(2020, 1, 1)
    record.save!(skip_timestamps: true)
    record.list_of_callback_events.clear
    record.note = "unsaved note"

    record.touch.should be_true

    fresh = T6TouchRecord.find!(record.id)
    fresh.note.should eq("old note")
    fresh.updated_at.should_not be_nil
    record.note.should eq("unsaved note")
    record.note_changed?.should be_true
    record.list_of_callback_events.should eq(["after_touch"])
  end

  it "touches named non-nullable Time columns" do
    old_time = Time.utc(2020, 1, 1)
    record = T6TouchRecord.create!(name: "required time", last_seen_at: old_time)

    record.touch(:last_seen_at).should be_true

    T6TouchRecord.find!(record.id).last_seen_at.should_not eq(old_time)
  end
end
