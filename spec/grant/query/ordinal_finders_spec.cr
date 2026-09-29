require "../../spec_helper"
require "../../support/relation_sql_capture"

class OrdinalCompositeLine < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table q01_ordinal_lines

  column region_id : Int64, primary: true
  column line_id : Int64, primary: true
  column label : String?

  composite_primary_key region_id, line_id
end

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Ordinal finders" do
  describe "take" do
    it "returns a row without adding ORDER BY" do
      seed_parents(["a", "b", "c"])

      statements = capture_sql { Parent.where("name != ?", "zzz").take.should_not be_nil }

      statements.size.should eq 1
      statements.first.should contain("LIMIT 1")
      statements.first.should_not contain("ORDER BY")
    end

    it "supports take(n), take! and the model-level forms" do
      seed_parents(["a", "b", "c"])
      relation = Parent.where("name != ?", "zzz")

      relation.take(2).size.should eq 2
      relation.take(10).size.should eq 3
      relation.take!.should be_a(Parent)
      Parent.take.should be_a(Parent)
      Parent.take(2).size.should eq 2
      Parent.take!.should be_a(Parent)
      Parent.where(name: "nope").take.should be_nil
      expect_raises(Grant::Querying::NotFound) { Parent.where(name: "nope").take! }
    end
  end

  describe "last(n)" do
    it "returns the last n rows in ascending order" do
      seed_parents(["a", "b", "c", "d"])

      Parent.order(:name).last(2).compact_map(&.name).should eq ["c", "d"]
      Parent.order(name: :desc).last(2).compact_map(&.name).should eq ["b", "a"]
      Parent.where("name != ?", "zzz").last(3).compact_map(&.name).should eq ["b", "c", "d"]
      Parent.last(2).compact_map(&.name).should eq ["c", "d"]
      Parent.last(10).size.should eq 4
      Parent.where(name: "nope").last(2).should be_empty
    end

    it "flips the ORDER BY and limits in SQL" do
      seed_parents(["a", "b"])

      sql = capture_sql { Parent.order(:name).last(1) }.first

      sql.should contain("ORDER BY name DESC")
      sql.should contain("LIMIT 1")
    end
  end

  describe "second through forty_two" do
    it "returns the nth record ordered by primary key" do
      seed_parents(%w(a b c d e f))
      ids = Parent.order(:id).to_a.compact_map(&.name)

      Parent.second.try(&.name).should eq ids[1]
      Parent.third.try(&.name).should eq ids[2]
      Parent.fourth.try(&.name).should eq ids[3]
      Parent.fifth.try(&.name).should eq ids[4]
      Parent.where("name != ?", "zzz").second.try(&.name).should eq ids[1]
      Parent.second_to_last.try(&.name).should eq ids[4]
      Parent.third_to_last.try(&.name).should eq ids[3]
    end

    it "returns nil when there are not enough rows and raises from the bang forms" do
      seed_parents(["a", "b"])

      Parent.third.should be_nil
      Parent.fourth.should be_nil
      Parent.fifth.should be_nil
      Parent.forty_two.should be_nil
      Parent.third_to_last.should be_nil
      Parent.where(name: "nope").second.should be_nil

      expect_raises(Grant::Querying::NotFound) { Parent.third! }
      expect_raises(Grant::Querying::NotFound) { Parent.fourth! }
      expect_raises(Grant::Querying::NotFound) { Parent.fifth! }
      expect_raises(Grant::Querying::NotFound) { Parent.forty_two! }
      expect_raises(Grant::Querying::NotFound) { Parent.third_to_last! }
      Parent.second!.should be_a(Parent)
      Parent.second_to_last!.should be_a(Parent)
    end

    it "finds the forty-second record with LIMIT 1 OFFSET 41" do
      Parent.clear
      44.times { |i| Parent.create(name: "p#{i.to_s.rjust(2, '0')}") }
      ordered = Parent.order(:id).to_a.compact_map(&.name)

      statements = capture_sql { Parent.forty_two.try(&.name).should eq ordered[41] }

      statements.size.should eq 1
      statements.first.should contain("LIMIT 1")
      statements.first.should contain("OFFSET 41")
      Parent.forty_two!.name.should eq ordered[41]
    end

    it "honors the relation's own order and offset" do
      seed_parents(%w(d a c b e))

      Parent.order(:name).second.try(&.name).should eq "b"
      Parent.order(name: :desc).second.try(&.name).should eq "d"
      Parent.order(:name).offset(1).second.try(&.name).should eq "c"
      Parent.order(:name).second_to_last.try(&.name).should eq "d"
      Parent.order(:name).third_to_last.try(&.name).should eq "c"
    end

    it "works on relations and never mutates them" do
      seed_parents(%w(a b c))
      relation = Parent.where("name != ?", "zzz")
      sql = relation.to_sql

      relation.second
      relation.third!
      relation.second_to_last

      relation.to_sql.should eq sql
      relation.offset.should be_nil
      relation.limit.should be_nil
    end
  end

  describe "on a relation with LIMIT or OFFSET" do
    it "keeps first, first(n) and the ordinals inside the limit" do
      seed_parents(%w(a b c d e))
      window = Parent.order(:name).limit(2)

      window.first(10).compact_map(&.name).should eq ["a", "b"]
      window.second.try(&.name).should eq "b"
      window.third.should be_nil
      Parent.order(:name).limit(1).second.should be_nil
      Parent.order(:name).limit(0).first.should be_nil
      Parent.order(:name).offset(1).limit(2).first(5).compact_map(&.name).should eq ["b", "c"]
    end

    it "reads last and the from-the-end ordinals from the window, not the table" do
      seed_parents(%w(a b c d e))

      Parent.order(:name).limit(3).last.try(&.name).should eq "c"
      Parent.order(:name).limit(3).last(2).compact_map(&.name).should eq ["b", "c"]
      Parent.order(:name).limit(3).second_to_last.try(&.name).should eq "b"
      Parent.order(:name).offset(1).limit(2).last.try(&.name).should eq "c"
      Parent.order(:name).offset(1).limit(3).second_to_last.try(&.name).should eq "c"
      Parent.order(:name).limit(2).third_to_last.should be_nil
    end

    it "answers nil from a loaded relation that is too short to count back" do
      seed_parents(["a"])
      loaded = Parent.order(:name).load

      loaded.second_to_last.should be_nil
      loaded.third_to_last.should be_nil
      loaded.last.try(&.name).should eq "a"
    end
  end

  describe "composite primary keys" do
    before_all do
      adapter = OrdinalCompositeLine.adapter
      adapter.open do |db|
        db.exec "DROP TABLE IF EXISTS q01_ordinal_lines"
        db.exec "CREATE TABLE q01_ordinal_lines (region_id BIGINT NOT NULL, line_id BIGINT NOT NULL, label VARCHAR(20), PRIMARY KEY (region_id, line_id))"
      end
    end

    before_each do
      OrdinalCompositeLine.adapter.open do |db|
        db.exec "DELETE FROM q01_ordinal_lines"
        [{2, 1, "r2l1"}, {1, 2, "r1l2"}, {1, 1, "r1l1"}, {2, 2, "r2l2"}].each do |region, line, label|
          db.exec "INSERT INTO q01_ordinal_lines (region_id, line_id, label) VALUES (#{region}, #{line}, '#{label}')"
        end
      end
    end

    it "orders by every primary key column" do
      OrdinalCompositeLine.where("label != ?", "zzz").implicit_order_columns.should eq ["region_id", "line_id"]

      OrdinalCompositeLine.where("label != ?", "zzz").first.try(&.label).should eq "r1l1"
      OrdinalCompositeLine.where("label != ?", "zzz").last.try(&.label).should eq "r2l2"
      OrdinalCompositeLine.where("label != ?", "zzz").second.try(&.label).should eq "r1l2"
      OrdinalCompositeLine.where("label != ?", "zzz").third.try(&.label).should eq "r2l1"
      OrdinalCompositeLine.where("label != ?", "zzz").second_to_last.try(&.label).should eq "r2l1"
      OrdinalCompositeLine.where("label != ?", "zzz").first(3).compact_map(&.label).should eq ["r1l1", "r1l2", "r2l1"]
      OrdinalCompositeLine.where("label != ?", "zzz").last(2).compact_map(&.label).should eq ["r2l1", "r2l2"]
    end

    it "emits every key column in the ORDER BY" do
      sql = capture_sql { OrdinalCompositeLine.where("label != ?", "zzz").first }.first

      sql.should contain("ORDER BY region_id ASC, line_id ASC")
    end
  end
end
