require "../../spec_helper"

class W6ufItem < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6uf_items

  column id : Int64, primary: true
  column title : String
  column status : String = "draft"
  column hits : Int32 = 0
  column seq : Int32 = 0

  validate :title, "must not be blank" do |item|
    !item.title.to_s.blank?
  end

  before_update :bump_hits

  def bump_hits
    self.hits = hits + 1
  end
end

private def seed_items : Array(W6ufItem)
  W6ufItem.clear
  ["a", "b", "c", "d"].map_with_index { |title, index| W6ufItem.create!(title: title, seq: index + 1) }
end

describe "Relation#update forms" do
  before_all { W6ufItem.migrator.drop_and_create }

  describe "update(hash)" do
    it "updates every matching record from a hash and runs callbacks" do
      items = seed_items
      updated = W6ufItem.where(:seq, :lteq, 2).update({"status" => "live"})
      updated.map(&.id).should eq(items.first(2).map(&.id))
      W6ufItem.where(status: "live").count.should eq(2)
      W6ufItem.where(hits: 1).count.should eq(2)
    end

    it "accepts symbol keys and named tuples" do
      seed_items
      W6ufItem.all.update({:status => "a"}).size.should eq(4)
      W6ufItem.all.update({status: "b"}).size.should eq(4)
      W6ufItem.where(status: "b").count.should eq(4)
    end

    it "returns records whose update failed validation, unsaved" do
      seed_items
      updated = W6ufItem.all.update({"title" => ""})
      updated.size.should eq(4)
      updated.each { |item| item.errors.should_not be_empty }
      W6ufItem.where(title: "").count.should eq(0)
    end

    it "update! raises, and rolls back the batch in progress" do
      seed_items
      expect_raises(Grant::RecordNotSaved) { W6ufItem.all.update!({"title" => ""}) }
      W6ufItem.where(hits: 0).count.should eq(4)
    end

    it "update! inside Model.transaction rolls back every record" do
      seed_items
      expect_raises(Grant::RecordNotSaved) do
        W6ufItem.transaction do
          W6ufItem.where(seq: 1).update!({"status" => "first"})
          W6ufItem.where(seq: 2).update!({"title" => ""})
        end
      end
      W6ufItem.where(status: "first").count.should eq(0)
    end
  end

  describe "update(id, hash)" do
    it "updates one record inside the relation" do
      items = seed_items
      record = W6ufItem.where(:seq, :gt, 1).update(items[1].id, {"status" => "pinned"})
      record.id.should eq(items[1].id)
      record.status.should eq("pinned")
      W6ufItem.find!(items[1].id).status.should eq("pinned")
    end

    it "raises NotFound for an id outside the relation" do
      items = seed_items
      expect_raises(Grant::Querying::NotFound) { W6ufItem.where(:seq, :gt, 1).update(items[0].id, {"status" => "x"}) }
      expect_raises(Grant::RecordNotSaved) { W6ufItem.all.update!(items[2].id, {"title" => ""}) }
    end
  end

  describe "update(ids, attributes_list)" do
    it "gives each id its own attributes and returns the records in id order" do
      items = seed_items
      updated = W6ufItem.all.update([items[2].id, items[0].id], [{"status" => "third"}, {"status" => "first"}])
      updated.map(&.id).should eq([items[2].id, items[0].id])
      updated.map(&.status).should eq(["third", "first"])
      W6ufItem.find!(items[0].id).status.should eq("first")
      W6ufItem.find!(items[2].id).status.should eq("third")
      W6ufItem.where(status: "draft").count.should eq(2)
    end

    it "runs callbacks and validations per record" do
      items = seed_items
      updated = W6ufItem.all.update([items[0].id, items[1].id], [{"status" => "ok"}, {"title" => ""}])
      updated[0].errors.should be_empty
      updated[1].errors.should_not be_empty
      W6ufItem.find!(items[0].id).hits.should eq(1)
      W6ufItem.find!(items[1].id).hits.should eq(0)
    end

    it "update! raises for the first invalid record" do
      items = seed_items
      expect_raises(Grant::RecordNotSaved) do
        W6ufItem.all.update!([items[0].id, items[1].id], [{"status" => "ok"}, {"title" => ""}])
      end
      W6ufItem.find!(items[0].id).status.should eq("draft")
    end

    it "is scoped to the relation: an id outside it raises NotFound" do
      items = seed_items
      expect_raises(Grant::Querying::NotFound) do
        W6ufItem.where(:seq, :gt, 1).update([items[0].id, items[1].id], [{"status" => "a"}, {"status" => "b"}])
      end
      W6ufItem.where(status: "draft").count.should eq(4)
    end

    it "rejects mismatched list sizes" do
      items = seed_items
      expect_raises(ArgumentError) { W6ufItem.all.update([items[0].id], [{"status" => "a"}, {"status" => "b"}]) }
    end

    it "handles an empty list and a repeated id" do
      items = seed_items
      W6ufItem.all.update([] of Int64, [] of Hash(String, String)).should be_empty
      updated = W6ufItem.all.update([items[0].id, items[0].id], [{"status" => "x"}, {"status" => "y"}])
      updated.map(&.status).should eq(["y", "y"])
      W6ufItem.find!(items[0].id).status.should eq("y")
    end

    it "works at the class level" do
      items = seed_items
      updated = W6ufItem.update([items[1].id, items[3].id], [{"status" => "two"}, {"status" => "four"}])
      updated.map(&.status).should eq(["two", "four"])
      W6ufItem.update!([items[0].id], [{"status" => "one"}]).first.status.should eq("one")
    end

    it "keeps the class-level form that applies one hash to many ids" do
      items = seed_items
      W6ufItem.update([items[0].id, items[1].id], {"status" => "same"}).map(&.status).should eq(["same", "same"])
    end
  end

  describe "update(:all, ...)" do
    it "updates every record in the relation" do
      seed_items
      W6ufItem.where(:seq, :gt, 2).update(:all, status: "late").size.should eq(2)
      W6ufItem.where(status: "late").count.should eq(2)
      expect_raises(ArgumentError) { W6ufItem.all.update(:some, status: "x") }
    end
  end

  describe "keyword forms keep working" do
    it "update(**attrs) and update(id, **attrs)" do
      items = seed_items
      W6ufItem.all.update(status: "k").size.should eq(4)
      W6ufItem.all.update(items[0].id, status: "one").status.should eq("one")
    end
  end
end
