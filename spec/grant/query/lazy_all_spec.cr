require "../../spec_helper"
require "../../support/relation_sql_capture"

class LazyAllScopedRow < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table q01_lazy_all_rows

  column id : Int64, primary: true
  column label : String?
  column visible : Bool = true
  column weight : Int32?

  default_scope { where(visible: true) }

  scope :heavy, ->(query : Grant::Query::Builder(LazyAllScopedRow)) { query.where("weight > ?", 5) }
  scope :by_label, ->(query : Grant::Query::Builder(LazyAllScopedRow)) { query.order(:label) }
end

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Lazy Model.all" do
  it "returns a relation and runs no SQL until it is read" do
    seed_parents(["a", "b"])

    relation = nil
    statements = capture_sql do
      relation = Parent.all.where(name: "a").order(:id).limit(5)
    end

    statements.should be_empty
    relation.should be_a(Grant::Query::Builder(Parent))
  end

  it "chains where, order, limit and offset after all" do
    seed_parents(["a", "b", "c", "d"])

    Parent.all.where("name != ?", "a").order(:name).limit(2).offset(1).to_a.compact_map(&.name).should eq ["c", "d"]
    Parent.all.where(name: ["a", "b"]).count.should eq 2
    Parent.all.where(name: "c").first.try(&.name).should eq "c"
  end

  it "supports Enumerable and size on the returned relation" do
    seed_parents(["a", "b", "c"])

    Parent.all.size.should eq 3
    Parent.all.map(&.name).compact.sort!.should eq ["a", "b", "c"]
    Parent.all.to_a.size.should eq 3
    Parent.all.select.size.should eq 3
    Parent.all.reduce(0) { |sum, _| sum + 1 }.should eq 3
  end

  it "loads a lazy relation once and reuses it across iterations" do
    seed_parents(["a", "b"])
    relation = Parent.all

    statements = capture_sql do
      relation.each { |_| }
      relation.each { |_| }
    end

    statements.size.should eq 1
  end

  it "makes relation.all a lazy copy" do
    seed_parents(["a", "b"])
    base = Parent.where("name != ?", "zzz")

    statements = capture_sql { base.all.order(:name) }

    statements.should be_empty
    base.all.should_not be(base)
    base.all.order(:name).limit(1).to_a.size.should eq 1
    base.order_fields.should be_empty
  end

  it "keeps the legacy Model.all(clause, params) overload returning an Array" do
    seed_parents(["a", "b"])

    found = Parent.all("WHERE name = ?", ["a"])
    found.should be_a(Array(Parent))
    found.size.should eq 1
    found.first.name.should eq "a"

    Parent.all("WHERE name = ? OR name = ?", ["a", "b"]).size.should eq 2
    Parent.all("ORDER BY name DESC").compact_map(&.name).should eq ["b", "a"]
  end

  it "keeps raw_all returning an Array" do
    seed_parents(["a"])

    Parent.raw_all("WHERE name = ?", ["a"]).should be_a(Array(Parent))
  end

  describe "with a default scope and named scopes" do
    before_all do
      LazyAllScopedRow.migrator.drop_and_create
    end

    before_each do
      LazyAllScopedRow.unscoped.delete_all
      LazyAllScopedRow.create(label: "b", visible: true, weight: 9)
      LazyAllScopedRow.create(label: "a", visible: true, weight: 1)
      LazyAllScopedRow.create(label: "hidden", visible: false, weight: 9)
    end

    it "applies the default scope to lazy all" do
      LazyAllScopedRow.all.size.should eq 2
      LazyAllScopedRow.all.where(weight: 9).to_a.compact_map(&.label).should eq ["b"]
      LazyAllScopedRow.unscoped.all.size.should eq 3
    end

    it "chains named scopes without leaking clauses into the base relation" do
      base = LazyAllScopedRow.heavy.all

      base.by_label.to_a.compact_map(&.label).should eq ["b"]
      base.by_label.should_not be(base)
      base.to_a.compact_map(&.label).should eq ["b"]
      base.order_fields.should be_empty
      base.where_fields.size.should eq 1
    end

    it "keeps named scopes composable in any order" do
      LazyAllScopedRow.by_label.heavy.to_a.compact_map(&.label).should eq ["b"]
      LazyAllScopedRow.heavy.where(label: "b").count.should eq 1
    end
  end
end
