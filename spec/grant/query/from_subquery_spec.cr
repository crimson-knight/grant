require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class FsqRow < Grant::Base
    connection {{ adapter_literal }}
    table fsq_rows
    column id : Int64, primary: true
    column label : String
    column score : Int64
    column team : String
  end

  class FsqOther < Grant::Base
    connection {{ adapter_literal }}
    table fsq_others
    column id : Int64, primary: true
    column label : String
  end
{% end %}

private def fsq_labels(relation : Grant::Query::Builder(FsqRow)) : Array(String)
  relation.order(:id).select.map(&.label.to_s)
end

describe "from (subquery as table)" do
  before_all do
    FsqRow.migrator.drop_and_create
    FsqOther.migrator.drop_and_create
  end

  before_each do
    FsqRow.clear
    FsqOther.clear
    FsqRow.create!(label: "a", score: 1_i64, team: "red")
    FsqRow.create!(label: "b", score: 5_i64, team: "red")
    FsqRow.create!(label: "c", score: 9_i64, team: "blue")
    FsqRow.create!(label: "d", score: 12_i64, team: "blue")
  end

  describe "with a relation" do
    it "selects from the subquery, aliased as the model table by default" do
      relation = FsqRow.from(FsqRow.where("score > ?", 4))
      sql = relation.to_sql
      sql.should contain("FROM (SELECT")
      sql.should contain(%(AS #{FsqRow.quote("fsq_rows")}))
      fsq_labels(relation).should eq(["b", "c", "d"])
    end

    it "carries the subquery binds before the outer binds, in order" do
      inner = FsqRow.where("score > ?", 4).where(team: "blue")
      relation = FsqRow.from(inner, as: "fsq_rows").where("score < ?", 12)
      assembler = relation.assembler
      assembler.select
      assembler.numbered_parameters.should eq([4_i64, "blue", 12_i64] of Grant::Columns::Type)
      if CURRENT_ADAPTER == "pg"
        relation.to_sql.should contain("$1")
        relation.to_sql.should contain("$3")
        relation.to_sql.index!("$1").should be < relation.to_sql.index!("$2")
        relation.to_sql.index!("$2").should be < relation.to_sql.index!("$3")
      end
      fsq_labels(relation).should eq(["c"])
    end

    it "nests a from inside a from without restarting the numbering" do
      innermost = FsqRow.where("score > ?", 1)
      middle = FsqRow.from(innermost).where("score < ?", 12)
      outer = FsqRow.from(middle).where(team: "red")
      assembler = outer.assembler
      assembler.select
      assembler.numbered_parameters.should eq([1_i64, 12_i64, "red"] of Grant::Columns::Type)
      fsq_labels(outer).should eq(["b"])
    end

    it "runs one statement, never the subquery on its own" do
      relation = FsqRow.from(FsqRow.where("score > ?", 4)).where(team: "blue")
      statements = capture_sql { relation.select.size.should eq(2) }
      statements.size.should eq(1)
    end

    it "accepts a relation over another model with an explicit alias" do
      FsqOther.create!(label: "z")
      relation = FsqRow.from(FsqOther.select(:id, :label), as: "fsq_rows").select(:id, :label).where("1 = ?", 1)
      relation.to_sql.should contain("fsq_others")
      relation.select.map(&.label).should eq(["z"])
    end

    it "snapshots the subquery when from is called" do
      inner = FsqRow.where("score > ?", 4)
      relation = FsqRow.from(inner)
      inner.where!(team: "red")
      fsq_labels(relation).should eq(["b", "c", "d"])
    end

    it "supports the finders and aggregates over the derived table" do
      relation = FsqRow.from(FsqRow.where("score > ?", 4))
      relation.count.should eq(3_i64)
      relation.exists?.should be_true
      relation.where(label: "a").exists?.should be_false
      relation.sum(:score).should eq(26_i64)
      relation.order(:score).first.not_nil!.label.should eq("b")
      relation.order(:score).limit(2).count.should eq(2_i64)
      relation.pluck(:label).flatten.map(&.to_s).sort!.should eq(["b", "c", "d"])
      relation.group_by(:team).count.to_s.should contain("blue")
    end

    it "supports a select list over the derived table" do
      relation = FsqRow.from(FsqRow.where("score > ?", 4).select(:id, :label)).select(:id, :label)
      relation.order(:id).select.map(&.label).should eq(["b", "c", "d"])
    end
  end

  describe "with raw SQL" do
    it "uses a SQL string as the source, with binds" do
      relation = FsqRow.from("(SELECT * FROM fsq_rows WHERE score > ?) recent", binds: [4_i64] of Grant::Columns::Type)
        .where(team: "red")
      relation.to_sql.should contain("FROM (SELECT * FROM fsq_rows WHERE score >")
      assembler = relation.assembler
      assembler.select
      assembler.numbered_parameters.should eq([4_i64, "red"] of Grant::Columns::Type)
      fsq_labels(relation).should eq(["b"])
    end

    it "aliases a plain table name" do
      relation = FsqRow.from("fsq_rows", as: "fsq_rows")
      relation.to_sql.should contain(%(FROM fsq_rows AS #{FsqRow.quote("fsq_rows")}))
      relation.count.should eq(4_i64)
    end

    it "rejects a placeholder count that does not match the binds" do
      expect_raises(ArgumentError, /placeholder count/) do
        FsqRow.from("(SELECT * FROM fsq_rows WHERE score > ?) recent").to_sql
      end
    end
  end

  describe "with a table name" do
    it "quotes a symbol source" do
      relation = FsqRow.from(:fsq_rows)
      relation.to_sql.should contain(%(FROM #{FsqRow.quote("fsq_rows")}))
      relation.count.should eq(4_i64)
    end

    it "rejects a source that is not an identifier" do
      expect_raises(ArgumentError, /not a valid identifier/) { FsqRow.from(:"fsq_rows; DROP TABLE x") }
      expect_raises(ArgumentError, /not a valid identifier/) { FsqRow.from(FsqRow.all, as: "x y") }
    end
  end

  describe "unscope(:from)" do
    it "goes back to the model table and keeps the other clauses" do
      relation = FsqRow.from(FsqRow.where("score > ?", 100)).where(team: "red")
      fsq_labels(relation).should be_empty
      restored = relation.unscope(:from)
      restored.to_sql.should_not contain("(SELECT")
      fsq_labels(restored).should eq(["a", "b"])
    end

    it "is available as except(:from) and leaves the receiver alone" do
      relation = FsqRow.from(FsqRow.where("score > ?", 100))
      fsq_labels(relation.except(:from)).size.should eq(4)
      fsq_labels(relation).should be_empty
      relation.only(:where).from_source?.should be_false
    end
  end

  describe "chaining" do
    it "does not change the relation it was called on" do
      base = FsqRow.where(team: "red")
      derived = base.from(FsqRow.where("score > ?", 1))
      base.from_source?.should be_false
      derived.from_source?.should be_true
      fsq_labels(base).should eq(["a", "b"])
    end

    it "takes the source of a merged relation" do
      merged = FsqRow.where(team: "blue").merge(FsqRow.from(FsqRow.where("score > ?", 10)))
      fsq_labels(merged).should eq(["d"])
    end

    it "works on the model class" do
      fsq_labels(FsqRow.from(FsqRow.where(team: "blue"))).should eq(["c", "d"])
    end
  end
end
