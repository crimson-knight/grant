require "../../spec_helper"
require "../../support/relation_sql_capture"

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Relation load memoization" do
  it "starts unloaded and loads once" do
    seed_parents(["a", "b"])
    relation = Parent.where("name != ?", "zzz")

    relation.loaded?.should be_false

    statements = capture_sql { relation.load }
    statements.size.should eq 1
    relation.loaded?.should be_true
    relation.records.size.should eq 2
  end

  it "runs one query for repeated each, to_a and records calls" do
    seed_parents(["a", "b", "c"])
    relation = Parent.where("name != ?", "zzz")
    seen = [] of String

    statements = capture_sql do
      relation.each { |parent| seen << parent.name.to_s }
      relation.each { |parent| seen << parent.name.to_s }
      relation.to_a
      relation.records
      relation.map(&.name)
    end

    statements.size.should eq 1
    seen.size.should eq 6
  end

  it "answers empty? with a LIMIT 1 probe, then each runs exactly one more query" do
    seed_parents(["a", "b", "c"])
    relation = Parent.where("name != ?", "zzz")

    probe = capture_sql { relation.empty?.should be_false }
    probe.size.should eq 1
    probe.first.should contain("LIMIT 1")
    relation.loaded?.should be_false

    load_statements = capture_sql { relation.each { |_| } }
    load_statements.size.should eq 1
    load_statements.first.should_not contain("LIMIT")

    capture_sql { relation.each { |_| } }.should be_empty
  end

  it "reads a loaded relation without SQL" do
    seed_parents(["a", "b", "c"])
    relation = Parent.where("name != ?", "zzz").order(:name).load

    statements = capture_sql do
      relation.empty?.should be_false
      relation.any?.should be_true
      relation.many?.should be_true
      relation.one?.should be_false
      relation.none?.should be_false
      relation.size.should eq 3
      relation.first.try(&.name).should eq "a"
      relation.last.try(&.name).should eq "c"
      relation.first(2).size.should eq 2
      relation.last(2).size.should eq 2
      relation.second.try(&.name).should eq "b"
    end

    statements.should be_empty
  end

  it "uses COUNT for size when the relation is not loaded" do
    seed_parents(["a", "b", "c"])
    relation = Parent.where("name != ?", "zzz")

    statements = capture_sql { relation.size.should eq 3 }

    statements.size.should eq 1
    statements.first.upcase.should contain("COUNT(*)")
    relation.loaded?.should be_false
  end

  it "resets and reloads to see new rows" do
    seed_parents(["a"])
    relation = Parent.where("name != ?", "zzz").load
    relation.size.should eq 1

    Parent.create(name: "b")
    relation.size.should eq 1
    relation.records.size.should eq 1

    relation.reset.should be(relation)
    relation.loaded?.should be_false
    relation.size.should eq 2
    relation.records.size.should eq 2

    Parent.create(name: "c")
    statements = capture_sql { relation.reload.should be(relation) }
    statements.size.should eq 1
    relation.loaded?.should be_true
    relation.records.size.should eq 3
  end

  it "hands back an unloaded relation from every chain method" do
    seed_parents(["a", "b"])
    loaded = Parent.where("name != ?", "zzz").load

    loaded.order(:name).loaded?.should be_false
    loaded.where(name: "a").loaded?.should be_false
    loaded.all.loaded?.should be_false
    loaded.limit(1).loaded?.should be_false
    loaded.loaded?.should be_true
  end

  it "drops the memoized records when a bang method changes the relation" do
    seed_parents(["a", "b"])
    relation = Parent.where("name != ?", "zzz").load
    relation.records.size.should eq 2

    relation.where!(name: "a")

    relation.loaded?.should be_false
    relation.records.size.should eq 1
  end

  it "returns the same records array until reset" do
    seed_parents(["a"])
    relation = Parent.where("name != ?", "zzz")

    relation.records.should be(relation.records)
  end

  it "treats none relations as loaded-empty without SQL" do
    seed_parents(["a"])
    relation = Parent.where("name != ?", "zzz").none

    capture_sql do
      relation.empty?.should be_true
      relation.any?.should be_false
      relation.many?.should be_false
      relation.records.should be_empty
    end.should be_empty
  end
end
