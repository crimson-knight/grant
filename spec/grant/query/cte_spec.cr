require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CteNode < Grant::Base
    connection {{ adapter_literal }}
    table cte_nodes
    column id : Int64, primary: true
    column parent_id : Int64?
    column label : String
    column weight : Int64
  end
{% end %}

private def cte_labels(relation : Grant::Query::Builder(CteNode)) : Array(String)
  relation.order(:id).select.map(&.label.to_s)
end

private def cte_tree_step : String
  "SELECT cte_nodes.id, cte_nodes.parent_id, cte_nodes.label, cte_nodes.weight " \
  "FROM cte_nodes INNER JOIN cte_tree ON cte_nodes.parent_id = cte_tree.id"
end

describe "common table expressions" do
  before_all { CteNode.migrator.drop_and_create }

  before_each do
    CteNode.clear
    root = CteNode.create!(label: "root", weight: 1_i64)
    left = CteNode.create!(label: "left", weight: 2_i64, parent_id: root.id)
    CteNode.create!(label: "leaf", weight: 3_i64, parent_id: left.id)
    CteNode.create!(label: "right", weight: 4_i64, parent_id: root.id)
    CteNode.create!(label: "island", weight: 5_i64)
  end

  describe "with" do
    it "renders WITH before the SELECT and reads from the CTE" do
      relation = CteNode.with(:heavy, CteNode.where("weight > ?", 2_i64)).from(:heavy)
      relation.to_sql.should start_with("WITH #{CteNode.quote("heavy")} AS (SELECT")
      relation.to_sql.should contain("FROM #{CteNode.quote("heavy")}")
      cte_labels(relation).should eq(["leaf", "right", "island"])
    end

    it "takes raw SQL with binds" do
      relation = CteNode.with(:heavy, "SELECT * FROM cte_nodes WHERE weight > ?", [3_i64] of Grant::Columns::Type).from(:heavy)
      cte_labels(relation).should eq(["right", "island"])
    end

    it "numbers binds CTE first, then the main query" do
      relation = CteNode
        .with(:heavy, CteNode.where("weight > ?", 1_i64))
        .with(:light, CteNode.where("weight < ?", 5_i64))
        .from(:heavy)
        .where("weight < ?", 4_i64)
        .where("id IN (SELECT id FROM #{CteNode.quote("light")} WHERE label != 'x')")
      assembler = relation.assembler
      assembler.select
      assembler.numbered_parameters.should eq([1_i64, 5_i64, 4_i64] of Grant::Columns::Type)
      if CURRENT_ADAPTER == "pg"
        sql = relation.to_sql
        sql.index!("$1").should be < sql.index!("$2")
        sql.index!("$2").should be < sql.index!("$3")
      end
      cte_labels(relation).should eq(["left", "leaf"])
    end

    it "keeps numbering when a CTE and a from subquery are combined" do
      relation = CteNode
        .with(:heavy, CteNode.where("weight > ?", 1_i64))
        .from(CteNode.where("weight < ?", 5_i64))
        .where("id IN (SELECT id FROM #{CteNode.quote("heavy")})")
        .where("weight > ?", 2_i64)
      assembler = relation.assembler
      assembler.select
      assembler.numbered_parameters.should eq([1_i64, 5_i64, 2_i64] of Grant::Columns::Type)
      cte_labels(relation).should eq(["leaf", "right"])
    end

    it "replaces a CTE added under the same name" do
      relation = CteNode.with(:pick, CteNode.where(label: "root")).with(:pick, CteNode.where(label: "leaf")).from(:pick)
      relation.common_tables.size.should eq(1)
      cte_labels(relation).should eq(["leaf"])
    end

    it "runs one statement" do
      relation = CteNode.with(:heavy, CteNode.where("weight > ?", 2_i64)).from(:heavy)
      capture_sql { relation.select.size.should eq(3) }.size.should eq(1)
    end

    it "works with count, exists?, pluck, first and aggregates" do
      relation = CteNode.with(:heavy, CteNode.where("weight > ?", 2_i64)).from(:heavy)
      relation.count.should eq(3_i64)
      relation.exists?.should be_true
      relation.where(label: "root").exists?.should be_false
      relation.sum(:weight).should eq(12_i64)
      relation.order(:id).first.not_nil!.label.should eq("leaf")
      relation.order(:id).pluck(:label).flatten.map(&.to_s).should eq(["leaf", "right", "island"])
      relation.distinct.count.should eq(3_i64)
      relation.order(:id).limit(2).count.should eq(2_i64)
    end

    it "does not change the relation it was called on and unscopes" do
      base = CteNode.where(label: "root")
      derived = base.with(:heavy, CteNode.all)
      base.common_tables.should be_empty
      derived.common_tables.size.should eq(1)
      derived.unscope(:with).common_tables.should be_empty
      derived.except(:with).to_sql.should_not contain("WITH")
    end

    it "carries CTEs through merge" do
      merged = CteNode.where("weight > ?", 0_i64).merge(CteNode.with(:one, CteNode.where(label: "root")).from(:one))
      cte_labels(merged).should eq(["root"])
    end

    it "rejects a name that is not an identifier" do
      expect_raises(ArgumentError, /not a valid identifier/) { CteNode.with("x; DROP TABLE y", CteNode.all) }
    end
  end

  describe "with_recursive" do
    it "walks a tree from its anchor rows" do
      relation = CteNode.with_recursive(:cte_tree, CteNode.where(label: "left"), cte_tree_step).from(:cte_tree)
      relation.to_sql.should start_with("WITH RECURSIVE #{CteNode.quote("cte_tree")} AS (")
      cte_labels(relation).should eq(["left", "leaf"])
      cte_labels(CteNode.with_recursive(:cte_tree, CteNode.where(label: "root"), cte_tree_step).from(:cte_tree))
        .should eq(["root", "left", "leaf", "right"])
    end

    it "accepts an anchor and step with binds, numbered in order" do
      step = cte_tree_step + " WHERE cte_nodes.weight < ?"
      relation = CteNode
        .with_recursive(:cte_tree, "SELECT * FROM cte_nodes WHERE label = ?", step,
          anchor_binds: ["root"] of Grant::Columns::Type, step_binds: [4_i64] of Grant::Columns::Type)
        .from(:cte_tree)
        .where("weight > ?", 1_i64)
      assembler = relation.assembler
      assembler.select
      assembler.numbered_parameters.should eq(["root", 4_i64, 1_i64] of Grant::Columns::Type)
      cte_labels(relation).should eq(["left", "leaf"])
    end

    it "can be used through a subselect in where" do
      relation = CteNode
        .with_recursive(:cte_tree, CteNode.where(label: "left"), cte_tree_step)
        .where("id IN (SELECT id FROM #{CteNode.quote("cte_tree")})")
      cte_labels(relation).should eq(["left", "leaf"])
    end

    it "stops a cycle at max_depth" do
      a = CteNode.create!(label: "cycle_a", weight: 9_i64)
      b = CteNode.create!(label: "cycle_b", weight: 9_i64, parent_id: a.id)
      a.parent_id = b.id
      a.save!

      relation = CteNode.with_recursive(:cte_tree, CteNode.where(label: "cycle_a"), cte_tree_step, max_depth: 4).from(:cte_tree)
      # anchor is depth 1; four levels in all, alternating b, a, b.
      relation.select.map(&.label).should eq(["cycle_a", "cycle_b", "cycle_a", "cycle_b"])
      relation.to_sql.should contain("grant_depth < 4")
    end

    it "applies a default depth guard" do
      Grant::Query::CommonTableExpressions::DEFAULT_MAX_DEPTH.should eq(1000)
      CteNode.with_recursive(:cte_tree, CteNode.where(label: "root"), cte_tree_step).to_sql
        .should contain("grant_depth < 1000")
    end

    it "adds the guard to an existing WHERE" do
      guarded = Grant::Query::CommonTableExpressions.guard_step(
        "SELECT a.id FROM a JOIN t ON a.p = t.id WHERE a.x = 'FROM WHERE' AND (a.y = 1)", 7)
      guarded.should eq("SELECT a.id, grant_depth + 1 FROM a JOIN t ON a.p = t.id WHERE grant_depth < 7 AND (a.x = 'FROM WHERE' AND (a.y = 1))")
    end

    it "ignores FROM inside parentheses and quotes" do
      guarded = Grant::Query::CommonTableExpressions.guard_step("SELECT EXTRACT(year FROM d), 'FROM' AS s FROM t", 3)
      guarded.should eq("SELECT EXTRACT(year FROM d), 'FROM' AS s, grant_depth + 1 FROM t WHERE grant_depth < 3")
    end

    it "rejects a step the guard cannot wrap" do
      expect_raises(ArgumentError, /must be SELECT/) { Grant::Query::CommonTableExpressions.guard_step("SELECT 1", 3) }
      expect_raises(ArgumentError, /cannot contain ORDER/) do
        Grant::Query::CommonTableExpressions.guard_step("SELECT a FROM t ORDER BY a", 3)
      end
      expect_raises(ArgumentError, /cannot contain LIMIT/) do
        Grant::Query::CommonTableExpressions.guard_step("SELECT a FROM t LIMIT 3", 3)
      end
      expect_raises(ArgumentError, /max_depth must be positive/) do
        Grant::Query::CommonTableExpressions.guard_step("SELECT a FROM t", 0)
      end
    end

    it "needs unguarded: true for a raw recursive body" do
      body = "SELECT id, parent_id, label, weight FROM cte_nodes WHERE label = 'left' " \
             "UNION ALL SELECT n.id, n.parent_id, n.label, n.weight FROM cte_nodes n INNER JOIN cte_tree t ON n.parent_id = t.id"
      expect_raises(ArgumentError, /unguarded: true/) { CteNode.with_recursive(:cte_tree, body, unguarded: false) }
      relation = CteNode.with_recursive(:cte_tree, body, unguarded: true).from(:cte_tree)
      cte_labels(relation).should eq(["left", "leaf"])
    end
  end

  describe "server support" do
    it "raises a named error on MySQL below 8" do
      old = Grant::Adapter::Mysql.new(name: "cte_mysql_5", url: "mysql://localhost/unused")
      old.database_version = Grant::ServerVersion.new(5, 7, 40)
      old.mariadb = false
      expect_raises(Grant::UnsupportedCommonTableExpressionError, /does not support common table expressions/) do
        Grant::Query::CommonTableExpressions.ensure_supported!(old)
      end

      current = Grant::Adapter::Mysql.new(name: "cte_mysql_8", url: "mysql://localhost/unused")
      current.database_version = Grant::ServerVersion.new(8, 0, 35)
      current.mariadb = false
      Grant::Query::CommonTableExpressions.ensure_supported!(current)
    end

    it "is an ErrorBase" do
      Grant::UnsupportedCommonTableExpressionError.new("x").should be_a(Grant::ErrorBase)
    end

    it "checks the adapter of the statement's model" do
      # The running adapter supports CTEs on PostgreSQL, SQLite and MySQL 8+.
      CteNode.with(:one, CteNode.all).from(:one).to_sql.should start_with("WITH")
    end
  end
end
