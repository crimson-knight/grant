require "../../spec_helper"
require "../../support/relation_sql_capture"

# Shares the parents table with Parent but orders first/last/find_each by name.
class ImplicitOrderParent < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table parents

  column id : Int64, primary: true
  column name : String?
  timestamps

  implicit_order_column :name
end

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Implicit ordering" do
  describe "the default" do
    it "no longer forces ORDER BY primary key DESC" do
      Grant.settings.implicit_order.should be_false

      Parent.where(name: "a").to_sql.should_not contain("ORDER BY")
      Parent.all.to_sql.should_not contain("ORDER BY")
      Parent.where("name != ?", "zzz").limit(3).to_sql.should_not contain("ORDER BY")
    end

    it "runs unordered reads without ORDER BY" do
      seed_parents(["a", "b"])

      statements = capture_sql { Parent.where("name != ?", "zzz").to_a }

      statements.size.should eq 1
      statements.first.should_not contain("ORDER BY")
    end

    it "still orders first, last and find_each by the primary key" do
      seed_parents(%w(c a b))
      ids = Parent.order(:id).to_a.map(&.id)

      Parent.first.try(&.id).should eq ids.first
      Parent.last.try(&.id).should eq ids.last
      Parent.where("name != ?", "zzz").first.try(&.id).should eq ids.first
      Parent.where("name != ?", "zzz").last.try(&.id).should eq ids.last

      seen = [] of Int64?
      Parent.find_each(batch_size: 2) { |parent| seen << parent.id }
      seen.should eq ids

      seen = [] of Int64?
      Parent.where("name != ?", "zzz").find_each(batch_size: 2) { |parent| seen << parent.id }
      seen.should eq ids
    end

    it "orders first ascending and last descending by primary key in SQL" do
      seed_parents(["a", "b"])

      capture_sql { Parent.first }.first.should contain("ORDER BY id ASC")
      capture_sql { Parent.last }.first.should contain("ORDER BY id DESC")
    end

    it "keeps an explicit ORDER BY untouched" do
      seed_parents(%w(c a b))

      Parent.order(:name).first.try(&.name).should eq "a"
      Parent.order(name: :desc).first.try(&.name).should eq "c"
      Parent.order(:name).last.try(&.name).should eq "c"
    end
  end

  describe "the legacy flag" do
    it "restores ORDER BY primary key DESC when Grant.settings.implicit_order is true" do
      seed_parents(%w(a b))

      begin
        Grant.settings.implicit_order = true

        Parent.where(name: "a").to_sql.should contain("ORDER BY")
        Parent.where(name: "a").to_sql.should contain("DESC")
        Parent.where("name != ?", "zzz").to_a.compact_map(&.name).should eq ["b", "a"]
        Parent.order(:name).to_sql.should contain("ORDER BY name ASC")
      ensure
        Grant.settings.implicit_order = false
      end

      Parent.where(name: "a").to_sql.should_not contain("ORDER BY")
    end
  end

  describe "implicit_order_column" do
    it "declares the columns" do
      ImplicitOrderParent.implicit_order_columns.should eq ["name"]
      Parent.implicit_order_columns.should be_empty
    end

    it "drives first and last, with the primary key as tiebreaker" do
      seed_parents(%w(c a b a))

      ImplicitOrderParent.first.try(&.name).should eq "a"
      ImplicitOrderParent.last.try(&.name).should eq "c"
      ImplicitOrderParent.where("name != ?", "zzz").first.try(&.name).should eq "a"
      ImplicitOrderParent.where("name != ?", "zzz").first(3).compact_map(&.name).should eq ["a", "a", "b"]
      ImplicitOrderParent.where("name != ?", "zzz").last(2).compact_map(&.name).should eq ["b", "c"]
      ImplicitOrderParent.second.try(&.name).should eq "a"
      ImplicitOrderParent.third.try(&.name).should eq "b"

      firsts = ImplicitOrderParent.where(name: "a").order(:id).to_a
      ImplicitOrderParent.where(name: "a").first.try(&.id).should eq firsts.first.id
      ImplicitOrderParent.where(name: "a").last.try(&.id).should eq firsts.last.id
    end

    it "puts the implicit columns and then the key in the SQL" do
      seed_parents(["a"])

      capture_sql { ImplicitOrderParent.where("name != ?", "zzz").first }.first.should contain("ORDER BY name ASC, id ASC")
      capture_sql { ImplicitOrderParent.where("name != ?", "zzz").last }.first.should contain("ORDER BY name DESC, id DESC")
    end

    it "drives find_each and find_in_batches" do
      seed_parents(%w(c a b d e))

      seen = [] of String?
      ImplicitOrderParent.where("name != ?", "zzz").find_each(batch_size: 2) { |parent| seen << parent.name }
      seen.should eq %w(a b c d e)

      seen = [] of String?
      ImplicitOrderParent.find_each(batch_size: 2) { |parent| seen << parent.name }
      seen.should eq %w(a b c d e)

      batches = [] of Array(String?)
      ImplicitOrderParent.where("name != ?", "zzz").find_in_batches(batch_size: 2) { |batch| batches << batch.map(&.name) }
      batches.should eq [["a", "b"], ["c", "d"], ["e"]]
    end

    it "does not order plain relations" do
      ImplicitOrderParent.where(name: "a").to_sql.should_not contain("ORDER BY")
      ImplicitOrderParent.all.to_sql.should_not contain("ORDER BY")
    end

    it "yields to an explicit order" do
      seed_parents(%w(c a b))

      ImplicitOrderParent.order(name: :desc).first.try(&.name).should eq "c"
      ImplicitOrderParent.order(name: :desc).last.try(&.name).should eq "a"
    end
  end
end
