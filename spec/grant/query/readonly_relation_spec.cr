require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class RoNote < Grant::Base
    connection {{ adapter_literal }}
    table ro_notes
    column id : Int64, primary: true
    column body : String
  end
{% end %}

describe "readonly relations" do
  before_all { RoNote.migrator.drop_and_create }

  before_each do
    RoNote.clear
    RoNote.create!(body: "one")
    RoNote.create!(body: "two")
  end

  it "marks every loaded record read-only" do
    records = RoNote.readonly.order(:id).select
    records.size.should eq(2)
    records.each(&.readonly?.should(be_true))
  end

  it "marks records from first, last, take and find_by paths" do
    RoNote.readonly.first!.readonly?.should be_true
    RoNote.readonly.last!.readonly?.should be_true
    RoNote.readonly.take!.readonly?.should be_true
    RoNote.readonly.where(body: "two").first!.readonly?.should be_true
    RoNote.readonly.each(&.readonly?.should(be_true))
    RoNote.readonly.to_a.each(&.readonly?.should(be_true))
  end

  it "marks records from streamed and batched loads" do
    streamed = [] of RoNote
    RoNote.readonly.each_streamed { |note| streamed << note }
    streamed.size.should eq(2)
    streamed.each(&.readonly?.should(be_true))

    batched = [] of RoNote
    RoNote.readonly.find_each(batch_size: 1) { |note| batched << note }
    batched.size.should eq(2)
    batched.each(&.readonly?.should(be_true))
  end

  it "leaves records from a plain relation writable" do
    RoNote.all.first!.readonly?.should be_false
  end

  it "prevents update, save and destroy with Grant::ReadOnlyRecordError" do
    note = RoNote.readonly.where(body: "one").first!
    expect_raises(Grant::ReadOnlyRecordError) { note.update(body: "changed") }
    expect_raises(Grant::ReadOnlyRecordError) { note.destroy }
    note.body = "changed"
    expect_raises(Grant::ReadOnlyRecordError) { note.save }
    RoNote.where(body: "one").count.should eq(1_i64)
  end

  it "can be switched off again" do
    RoNote.readonly.readonly(false).first!.readonly?.should be_false
    RoNote.readonly.unscope(:readonly).first!.readonly?.should be_false
    RoNote.readonly.except(:readonly).first!.readonly?.should be_false
  end

  it "survives chaining and merging" do
    RoNote.readonly.where(body: "one").order(:id).limit(1).first!.readonly?.should be_true
    RoNote.all.merge(RoNote.readonly).first!.readonly?.should be_true
  end

  it "does not change the receiver" do
    base = RoNote.where(body: "one")
    base.readonly
    base.readonly?.should be_false
    base.first!.readonly?.should be_false
  end

  it "has a bang form" do
    relation = RoNote.all
    relation.readonly!
    relation.readonly?.should be_true
    relation.first!.readonly?.should be_true
  end

  it "adds no query" do
    plain = RoNote.where(body: "one").raw_sql
    RoNote.readonly.where(body: "one").raw_sql.should eq(plain)
  end
end
