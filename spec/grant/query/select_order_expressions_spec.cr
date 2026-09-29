require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SoTeam < Grant::Base
    connection {{ adapter_literal }}
    table so_teams
    column id : Int64, primary: true
    column label : String
    has_many :players, class_name: SoPlayer, foreign_key: :so_team_id
  end

  class SoPlayer < Grant::Base
    connection {{ adapter_literal }}
    table so_players
    column id : Int64, primary: true
    column name : String?
    column position : String
    column score : Int64
    column so_team_id : Int64?
    belongs_to :so_team, class_name: SoTeam, foreign_key: :so_team_id, optional: true
  end
{% end %}

private def names(relation) : Array(String?)
  relation.select.map(&.name)
end

describe "select and order expressions" do
  before_all do
    SoTeam.migrator.drop_and_create
    SoPlayer.migrator.drop_and_create
  end

  before_each do
    SoPlayer.clear
    SoTeam.clear
    reds = SoTeam.create!(label: "Reds")
    blues = SoTeam.create!(label: "Blues")
    SoPlayer.create!(name: "beta", position: "guard", score: 5_i64, so_team_id: reds.id)
    SoPlayer.create!(name: "Alpha", position: "guard", score: 9_i64, so_team_id: reds.id)
    SoPlayer.create!(name: nil, position: "wing", score: 7_i64, so_team_id: blues.id)
    SoPlayer.create!(name: "gamma", position: "wing", score: 2_i64, so_team_id: blues.id)
  end

  describe "select with SQL expressions" do
    it "adds a computed column reachable through extra_attribute" do
      row = SoPlayer.where(position: "guard").select(:position, "COUNT(*) AS total").group(:position).select.first
      row.position.should eq("guard")
      row.extra_attribute("total", Int64).should eq(2_i64)
      row.extra_attributes.keys.should eq(["total"])
      row.extra_attribute(:total).should eq(2_i64)
      expect_raises(TypeCastError, /"total" is Int64, not String/) { row.extra_attribute("total", String) }
      expect_raises(TypeCastError, /"missing" is Nil/) { row.extra_attribute("missing", Int64) }
      row.extra_attribute("missing", Int64?).should be_nil
    end

    it "reads the columns that follow a computed column" do
      row = SoPlayer.order(:id).select(:id, "score * 2 AS doubled", :position).select.first
      row.id.should_not be_nil
      row.position.should eq("guard")
      row.extra_attribute("doubled", Int64).should eq(10_i64)
    end

    it "supports several aliases and a bare expression" do
      row = SoPlayer.order(:id).select(:name, "score + 1 AS next_score", "upper(position) AS shout").select.first
      row.extra_attribute("next_score", Int64).should eq(6_i64)
      row.extra_attribute("shout", String).should eq("GUARD")
    end

    it "gives nil for a column that was not selected" do
      SoPlayer.select(:name).select.first.extra_attribute("nothing").should be_nil
      SoPlayer.select(:name).select.first.extra_attributes.should be_empty
    end

    it "keeps the symbol form and the block form" do
      SoPlayer.select(:id, :name).select.size.should eq(4)
      SoPlayer.order(:id).select { |player| player.score > 6 }.map(&.score).should eq([9_i64, 7_i64])
    end

    it "replaces the list with reselect" do
      relation = SoPlayer.select("score AS s").reselect("position AS p")
      relation.raw_sql.should contain("position AS p")
      relation.raw_sql.should_not contain("score AS s")
    end

    it "qualifies plain columns when joins are present and leaves expressions alone" do
      sql = SoPlayer.joins(:so_team).select(:name, "so_teams.label AS team").raw_sql
      sql.should contain("SELECT #{SoPlayer.quote("so_players")}.#{SoPlayer.quote("name")}, so_teams.label AS team")
      row = SoPlayer.joins(:so_team).where(name: "Alpha").select(:name, "so_teams.label AS team").select.first
      row.extra_attribute("team", String).should eq("Reds")
    end

    it "refuses an expression that is not a single clause" do
      expect_raises(ArgumentError, /statement separator/) { SoPlayer.select("1; DROP TABLE so_players") }
      expect_raises(ArgumentError, /unbalanced/) { SoPlayer.select("count(*") }
    end
  end

  describe "order with SQL" do
    it "orders by a raw expression with its own direction" do
      names(SoPlayer.where("name IS NOT NULL").order("lower(name) DESC")).should eq(["gamma", "beta", "Alpha"])
      names(SoPlayer.where("name IS NOT NULL").order("lower(name)")).should eq(["Alpha", "beta", "gamma"])
    end

    it "orders by several comma-separated terms" do
      relation = SoPlayer.order("position DESC, score ASC")
      relation.select.map(&.score).should eq([2_i64, 7_i64, 5_i64, 9_i64])
    end

    it "does not split on commas inside a function call" do
      SoPlayer.order("coalesce(name, position) DESC, id").order_fields.size.should eq(2)
    end

    it "keeps plain terms structured" do
      terms = SoPlayer.order("position DESC").order_fields
      terms.first[:field].should eq("position")
      terms.first[:direction].should eq(Grant::Query::Builder::Sort::Descending)
    end

    it "orders on a joined-table column by qualified name" do
      SoPlayer.joins(:so_team).order("so_teams.label", :asc).order(score: :desc).select.map(&.score).should eq([7_i64, 2_i64, 9_i64, 5_i64])
      SoPlayer.joins(:so_team).order("so_teams.label": :desc, "so_players.score": :asc).select.map(&.score).should eq([5_i64, 9_i64, 2_i64, 7_i64])
    end

    it "rejects an unknown table qualifier" do
      expect_raises(ArgumentError, /Unknown query table "nope"/) { SoPlayer.joins(:so_team).order("nope.label", :asc).to_sql }
    end

    it "refuses an expression that is not a single clause" do
      expect_raises(ArgumentError, /statement separator/) { SoPlayer.order("id; DROP TABLE so_players") }
      expect_raises(ArgumentError, /comment marker/) { SoPlayer.order("id /* x */") }
    end

    it "rejects raw SQL that is not a function of columns, like ActiveRecord" do
      expect_raises(ArgumentError, /not a column or a function of columns/) { SoPlayer.order("(SELECT 1) DESC") }
      expect_raises(ArgumentError, /not a column or a function of columns/) { SoPlayer.order("CASE WHEN score > 5 THEN 0 ELSE 1 END") }
      expect_raises(ArgumentError, /not a column or a function of columns/) { SoPlayer.order("pg_sleep(1)") }
      expect_raises(ArgumentError, /not a column or a function of columns/) { SoPlayer.order("lower('x')") }
      expect_raises(ArgumentError, /not a column or a function of columns/) { SoPlayer.order("score + 1", :desc) }
    end

    it "accepts SQL wrapped in Grant.sql" do
      relation = SoPlayer.order(Grant.sql("CASE WHEN score > 5 THEN 0 ELSE 1 END, score"))
      relation.select.map(&.score).should eq([7_i64, 9_i64, 2_i64, 5_i64])
      expect_raises(ArgumentError, /statement separator/) { SoPlayer.order(Grant.sql("id; DROP TABLE so_players")) }
    end

    it "reverses raw and structured terms" do
      SoPlayer.order("lower(position) DESC, score").reverse_order.raw_sql.should contain("lower(position) ASC, score DESC")
      SoPlayer.order(:position, :asc, nulls: :last).reverse_order.order_fields.first[:direction]
        .should eq(Grant::Query::Builder::Sort::DescendingNullsFirst)
    end

    it "orders a raw expression after loading through last" do
      SoPlayer.where("name IS NOT NULL").order("lower(name)").last.not_nil!.name.should eq("gamma")
    end
  end

  describe "NULLS FIRST and NULLS LAST" do
    it "places NULLs first or last on both directions" do
      names(SoPlayer.order(:name, nulls: :first)).first.should be_nil
      names(SoPlayer.order(:name, nulls: :last)).last.should be_nil
      names(SoPlayer.order(:name, :desc, nulls: :first)).first.should be_nil
      names(SoPlayer.order(:name, :desc, nulls: :last)).last.should be_nil
      names(SoPlayer.order(:name, :asc, nulls: :last)).compact.should eq(["Alpha", "beta", "gamma"])
    end

    it "accepts NULLS in an order string" do
      names(SoPlayer.order("name ASC NULLS LAST")).last.should be_nil
      names(SoPlayer.order("name desc nulls first")).first.should be_nil
      SoPlayer.order("name NULLS FIRST").order_fields.first[:direction].should eq(Grant::Query::Builder::Sort::AscendingNullsFirst)
    end

    it "renders NULLS FIRST/LAST natively on PostgreSQL and SQLite" do
      sql = Grant::Query::Assembler::Pg(SoPlayer).new(SoPlayer.order(:name, :desc, nulls: :last)).order.not_nil!
      sql.should contain("DESC NULLS LAST")
      Grant::Query::Assembler::Sqlite(SoPlayer).new(SoPlayer.order(:name, nulls: :first)).order.not_nil!.should contain("ASC NULLS FIRST")
    end

    it "emulates NULLS FIRST/LAST with ISNULL on MySQL" do
      last = Grant::Query::Assembler::Mysql(SoPlayer).new(SoPlayer.order(:name, :asc, nulls: :last)).order.not_nil!
      last.should contain("ISNULL(name) ASC, name ASC")
      first = Grant::Query::Assembler::Mysql(SoPlayer).new(SoPlayer.order(:name, :desc, nulls: :first)).order.not_nil!
      first.should contain("ISNULL(name) DESC, name DESC")
      last.should_not contain("NULLS")
    end

    it "qualifies the emulation when joins are present" do
      sql = Grant::Query::Assembler::Mysql(SoPlayer).new(SoPlayer.joins(:so_team).order(:name, nulls: :last)).order.not_nil!
      sql.should contain("ISNULL(#{SoPlayer.quote("so_players")}.#{SoPlayer.quote("name")})")
    end

    it "batches ascending when the primary key order carries a NULL placement" do
      ids = SoPlayer.order(:id).select.map(&.id.not_nil!)
      seen = [] of Int64
      SoPlayer.order(:id, :asc, nulls: :last).in_batches(of: 1, start: ids[1]) { |batch| batch.each { |player| seen << player.id.not_nil! } }
      seen.should eq(ids[1..])
    end

    it "validates the placement and direction" do
      expect_raises(ArgumentError, /nulls must be :first or :last/) { SoPlayer.order(:name, nulls: :middle) }
      expect_raises(ArgumentError, /direction must be :asc or :desc/) { SoPlayer.order(:name, :sideways) }
      expect_raises(ArgumentError, /column name/) { SoPlayer.order("lower(name)", :asc, nulls: :last) }
    end
  end
end
