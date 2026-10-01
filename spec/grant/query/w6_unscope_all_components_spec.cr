require "../../spec_helper"

class W6usAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6us_authors

  column id : Int64, primary: true
  column name : String?

  has_many :notes, class_name: W6usNote, foreign_key: author_id
end

class W6usNote < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6us_notes

  column id : Int64, primary: true
  column title : String?
  column kind : String?
  column rank : Int32 = 0
  column author_id : Int64?

  belongs_to :author, class_name: W6usAuthor, foreign_key: author_id, optional: true
end

private def titles(relation : Grant::Query::Builder(W6usNote)) : Array(String)
  relation.select.map { |note| note.title.to_s }
end

describe "unscope for every relation component" do
  before_all do
    W6usAuthor.migrator.drop_and_create
    W6usNote.migrator.drop_and_create
  end

  before_each do
    W6usNote.clear
    W6usAuthor.clear
    ann = W6usAuthor.create!(name: "ann")
    W6usNote.create!(title: "a", kind: "x", rank: 3, author_id: ann.id)
    W6usNote.create!(title: "b", kind: "y", rank: 2, author_id: ann.id)
    W6usNote.create!(title: "c", kind: "x", rank: 1)
  end

  describe "components that already worked" do
    it "unscopes where, order, limit, offset, group, having, joins, select and distinct" do
      base = W6usNote.where(kind: "x").order(:title).limit(1).offset(1).group_by(:kind).having("COUNT(*) > ?", 1).joins(:author).select(:title).distinct
      sql = base.unscope(:where, :order, :limit, :offset, :group, :having, :joins, :select, :distinct).to_sql
      sql.should_not contain("WHERE")
      sql.should_not contain("ORDER BY")
      sql.should_not contain("LIMIT")
      sql.should_not contain("OFFSET")
      sql.should_not contain("GROUP BY")
      sql.should_not contain("HAVING")
      sql.should_not contain("JOIN")
      sql.should_not contain("DISTINCT")
    end

    it "unscopes lock" do
      W6usNote.lock.unscope(:lock).to_sql.should_not contain("FOR UPDATE")
    end
  end

  describe ":readonly" do
    it "clears the read-only flag" do
      W6usNote.readonly.unscope(:readonly).readonly?.should be_false
      W6usNote.readonly.readonly?.should be_true
    end
  end

  describe ":annotate" do
    it "drops the SQL comment" do
      annotated = W6usNote.where(kind: "x").annotate("from tests")
      annotated.to_sql.should contain("from tests")
      annotated.unscope(:annotate).to_sql.should_not contain("from tests")
      annotated.to_sql.should contain("from tests")
    end
  end

  describe ":optimizer_hints" do
    it "drops the hint comment" do
      hinted = W6usNote.optimizer_hints("MAX_EXECUTION_TIME(10)")
      hinted.to_sql.should contain("MAX_EXECUTION_TIME(10)")
      hinted.unscope(:optimizer_hints).to_sql.should_not contain("MAX_EXECUTION_TIME")
    end
  end

  describe ":from and :with" do
    it "drops a from override" do
      sourced = W6usNote.from(W6usNote.where(kind: "x"), as: "sub")
      sourced.to_sql.should contain("sub")
      sourced.unscope(:from).to_sql.should_not contain("sub")
      titles(sourced.unscope(:from)).sort!.should eq(["a", "b", "c"])
    end

    it "drops common table expressions" do
      withed = W6usNote.with(:picked, W6usNote.where(kind: "x"))
      withed.to_sql.should contain("WITH")
      withed.unscope(:with).to_sql.should_not contain("WITH")
    end
  end

  describe ":includes, :preload and :eager_load" do
    it "drops each eager-loading list" do
      W6usNote.includes(:author).unscope(:includes).includes_associations.should be_empty
      W6usNote.preload(:author).unscope(:preload).preload_associations.should be_empty
      W6usNote.eager_load(:author).unscope(:eager_load).eager_load_associations.should be_empty
    end
  end

  describe ":reordering" do
    it "clears the reorder marker, so a merge appends again" do
      reordered = W6usNote.order(:title).reorder(:rank)
      reordered.reordering?.should be_true
      reordered.unscope(:reordering).reordering?.should be_false
      appended = W6usNote.order(:kind).merge(reordered.unscope(:reordering))
      appended.order_fields.map { |term| term[:field] }.should eq(["kind", "rank"])
    end

    it "does not remove the order terms themselves" do
      W6usNote.order(:rank).reorder(:title).unscope(:reordering).order_fields.map { |term| term[:field] }.should eq(["title"])
    end
  end

  describe ":create_with" do
    it "drops the defaults of create_with" do
      scoped = W6usNote.create_with(kind: "z")
      scoped.build(title: "t").kind.should eq("z")
      scoped.unscope(:create_with).build(title: "t").kind.should be_nil
      scoped.create_with_attributes.should eq({"kind" => "z"})
    end

    it "keeps equality predicates, which still seed new records" do
      W6usNote.where(kind: "x").create_with(title: "t").unscope(:create_with).build(title: "t").kind.should eq("x")
    end
  end

  describe ":extending" do
    it "is accepted and changes nothing, because a relation holds no extension modules" do
      relation = W6usNote.where(kind: "x")
      relation.unscope(:extending).to_sql.should eq(relation.to_sql)
    end
  end

  describe "errors" do
    it "still rejects an unknown component" do
      expect_raises(ArgumentError, /unknown component/) { W6usNote.unscope(:bogus) }
    end
  end

  describe "bang and merge forms" do
    it "unscope! changes the receiver" do
      relation = W6usNote.order(:title).annotate("x")
      relation.unscope!(:order, :annotate)
      relation.order_fields.should be_empty
      relation.to_sql.should_not contain("/*")
    end

    it "an unscoped relation passed to merge applies its unscoping to the receiver" do
      merged = W6usNote.where(kind: "x").annotate("zzmark").merge(W6usNote.unscope(:annotate, :where))
      merged.to_sql.should_not contain("zzmark")
      titles(merged).sort!.should eq(["a", "b", "c"])
    end
  end
end
