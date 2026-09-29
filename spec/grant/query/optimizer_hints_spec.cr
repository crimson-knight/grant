require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class OhRow < Grant::Base
    connection {{ adapter_literal }}
    table oh_rows
    column id : Int64, primary: true
    column label : String
  end
{% end %}

describe "optimizer hints" do
  before_all { OhRow.migrator.drop_and_create }

  before_each do
    OhRow.clear
    OhRow.create!(label: "a")
    OhRow.create!(label: "b")
  end

  it "renders a /*+ ... */ comment right after SELECT" do
    sql = OhRow.optimizer_hints("MAX_EXECUTION_TIME(1000)").raw_sql
    sql.should contain("SELECT /*+ MAX_EXECUTION_TIME(1000) */ ")
    sql.index!("/*+").should be < sql.index!("FROM")
  end

  it "joins several hints with a space" do
    OhRow.optimizer_hints("SeqScan(oh_rows)", "Parallel(oh_rows 2)").raw_sql
      .should contain("SELECT /*+ SeqScan(oh_rows) Parallel(oh_rows 2) */ ")
    OhRow.optimizer_hints("A").optimizer_hints("B").raw_sql.should contain("/*+ A B */")
  end

  it "sits before DISTINCT" do
    OhRow.distinct.optimizer_hints("HINT(x)").raw_sql.should contain("SELECT /*+ HINT(x) */ DISTINCT")
  end

  it "strips the comment terminator so a hint cannot inject SQL" do
    sql = OhRow.optimizer_hints("HINT(x) */ DROP TABLE oh_rows; /*").raw_sql
    sql.scan("*/").size.should eq(1)
    sql.scan("/*").size.should eq(1)
    sql.should contain("/*+ HINT(x)  DROP TABLE oh_rows; */")
    OhRow.optimizer_hints("**//").raw_sql.should_not contain("**//")
    OhRow.count.should eq(2_i64)
    OhRow.optimizer_hints("HINT(x) */ SELECT 1 /*").select.size.should eq(2)
  end

  it "drops blank hints" do
    OhRow.optimizer_hints("  ", "*/").optimizer_hint_list.should be_empty
    OhRow.optimizer_hints("  ", "*/").raw_sql.should_not contain("/*+")
  end

  it "does not change results" do
    OhRow.optimizer_hints("MAX_EXECUTION_TIME(1000)").order(:id).select.map(&.label).should eq(["a", "b"])
    OhRow.optimizer_hints("HINT(x)").where(label: "a").count.should eq(1_i64)
    OhRow.optimizer_hints("HINT(x)").group(:label).count.is_a?(Hash).should be_true
    capture_sql { OhRow.optimizer_hints("HINT(x)").count }.first.should start_with("SELECT /*+ HINT(x) */ COUNT(*)")
    OhRow.optimizer_hints("HINT(x)").where(label: "a").first!.label.should eq("a")
    OhRow.optimizer_hints("HINT(x)").pluck(:label).size.should eq(2)
    OhRow.optimizer_hints("HINT(x)").sum(:id).should eq(OhRow.all.sum(:id))
  end

  it "is dropped by unscope and except" do
    OhRow.optimizer_hints("HINT(x)").unscope(:optimizer_hints).raw_sql.should_not contain("/*+")
    OhRow.optimizer_hints("HINT(x)").except(:optimizer_hints).optimizer_hint_list.should be_empty
  end

  it "coexists with an annotation and an index hint" do
    sql = OhRow.annotate("from spec").optimizer_hints("HINT(x)").raw_sql
    sql.should start_with("/* from spec */ SELECT /*+ HINT(x) */")
  end

  it "does not change the receiver, and merges" do
    base = OhRow.where(label: "a")
    base.optimizer_hints("HINT(x)")
    base.optimizer_hint_list.should be_empty
    OhRow.all.merge(OhRow.optimizer_hints("HINT(y)")).optimizer_hint_list.should eq(["HINT(y)"])
    OhRow.optimizer_hints("HINT(y)").merge(OhRow.optimizer_hints("HINT(y)", "HINT(z)")).optimizer_hint_list.should eq(["HINT(y)", "HINT(z)"])
  end

  it "has a bang form" do
    relation = OhRow.all
    relation.optimizer_hints!("HINT(x)")
    relation.optimizer_hint_list.should eq(["HINT(x)"])
  end
end
