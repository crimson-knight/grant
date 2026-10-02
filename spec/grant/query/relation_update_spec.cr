require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class RelationUpdateItem < Grant::Base
    connection {{ adapter_literal }}
    table relation_update_items

    column id : Int64, primary: true
    column title : String
    column status : String = "draft"
    column touched_by_callback : Bool = false

    validate :title, "must not be blank" do |item|
      !item.title.to_s.blank?
    end

    before_update :mark_touched

    def mark_touched
      self.touched_by_callback = true
    end
  end

  class RelationUpdateRanked < Grant::Base
    connection {{ adapter_literal }}
    table relation_update_ranked

    column id : Int64, primary: true
    column rank : Int64
    column saves : Int64 = 0_i64

    before_update :count_save

    def count_save
      self.saves = saves + 1
    end
  end
{% end %}

private def seed_update_items : Array(RelationUpdateItem)
  RelationUpdateItem.migrator.drop_and_create
  ["a", "b", "c", "d"].map { |title| RelationUpdateItem.create!(title: title) }
end

describe "Relation update and update!" do
  it "updates each matching record with callbacks and returns the records" do
    items = seed_update_items

    updated = RelationUpdateItem.where(:id, :lteq, items[2].id!).update(status: "live")

    updated.map(&.id!).should eq(items.first(3).map(&.id!))
    updated.each(&.status.should(eq("live")))
    RelationUpdateItem.where(status: "live").count.should eq(3)
    RelationUpdateItem.where(touched_by_callback: true).count.should eq(3)
    RelationUpdateItem.where(status: "draft").count.should eq(1)
  end

  it "runs validations and reports failed records without persisting them" do
    seed_update_items

    updated = RelationUpdateItem.all.update(title: "")

    updated.size.should eq(4)
    updated.each(&.errors.should_not(be_empty))
    RelationUpdateItem.where(title: "").count.should eq(0)
  end

  it "raises from update! and rolls back the batch in progress" do
    seed_update_items

    expect_raises(Grant::RecordNotSaved) do
      RelationUpdateItem.all.update!(title: "")
    end
    RelationUpdateItem.where(title: "").count.should eq(0)
    RelationUpdateItem.where(touched_by_callback: true).count.should eq(0)
  end

  it "updates one record by id inside the relation" do
    items = seed_update_items

    record = RelationUpdateItem.where(:id, :gt, items[0].id!).update(items[1].id!, status: "pinned")
    record.id.should eq(items[1].id)
    record.status.should eq("pinned")
    RelationUpdateItem.find!(items[1].id!).status.should eq("pinned")

    expect_raises(Grant::Querying::NotFound) do
      RelationUpdateItem.where(:id, :gt, items[0].id!).update(items[0].id!, status: "x")
    end
    expect_raises(Grant::RecordNotSaved) do
      RelationUpdateItem.all.update!(items[2].id!, title: "")
    end
  end

  it "does not touch rows outside the relation and returns an empty array for none" do
    items = seed_update_items
    RelationUpdateItem.where(title: "nope").update(status: "live").should be_empty
    RelationUpdateItem.none.update(status: "live").should be_empty
    RelationUpdateItem.where(status: "live").count.should eq(0)
    items.size.should eq(4)
  end

  it "updates each row once when the update moves it along the relation's order" do
    RelationUpdateRanked.migrator.drop_and_create
    rows = (1..1005).map { |rank| {"rank" => rank.to_i64.as(Grant::Columns::Type)} of String | Symbol => Grant::Columns::Type }
    RelationUpdateRanked.insert_all(rows, record_timestamps: false)

    updated = RelationUpdateRanked.order(rank: :asc).update(rank: 5000_i64)

    updated.size.should eq(1005)
    updated.map(&.id!).uniq!.size.should eq(1005)
    RelationUpdateRanked.where(saves: 1_i64).count.should eq(1005)
  end

  it "updates only the rows an ordered, limited relation selects" do
    RelationUpdateRanked.migrator.drop_and_create
    (1..5).each { |rank| RelationUpdateRanked.create!(rank: rank.to_i64) }

    updated = RelationUpdateRanked.order(rank: :desc).limit(2).update(rank: 0_i64)

    updated.size.should eq(2)
    RelationUpdateRanked.order(:id).pluck(:rank).map(&.first).should eq([1_i64, 2_i64, 3_i64, 0_i64, 0_i64])
  end
end
