require "../../spec_helper"
require "../../support/relation_sql_capture"

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Relation clause components" do
  describe "only and except" do
    it "except drops the named components and returns a copy" do
      base = Parent.where(name: "a").order(:name).limit(5).offset(2)

      trimmed = base.except(:order, :limit)

      trimmed.order_fields.should be_empty
      trimmed.limit.should be_nil
      trimmed.offset.should eq 2
      trimmed.where_fields.size.should eq 1
      base.order_fields.size.should eq 1
      base.limit.should eq 5
    end

    it "only keeps just the named components" do
      base = Parent.where(name: "a").order(:name).limit(5).offset(2).group_by(:name).distinct

      kept = base.only(:where, :order)

      kept.where_fields.size.should eq 1
      kept.order_fields.size.should eq 1
      kept.limit.should be_nil
      kept.offset.should be_nil
      kept.group_fields.should be_empty
      kept.distinct?.should be_false
      base.limit.should eq 5
      base.group_fields.size.should eq 1
    end

    it "only(:where) yields a pure filter" do
      only_where = Parent.where(name: "a").order(:name).limit(1).only(:where)

      only_where.to_sql.should contain("WHERE")
      only_where.to_sql.should_not contain("ORDER BY")
      only_where.to_sql.should_not contain("LIMIT")
    end

    it "rejects unknown components" do
      expect_raises(ArgumentError, /only: unknown component/) { Parent.where(name: "a").only(:bogus) }
      expect_raises(ArgumentError, /unknown component/) { Parent.where(name: "a").except(:bogus) }
    end

    it "runs the trimmed relation" do
      seed_parents(%w(a b c))

      Parent.where("name != ?", "a").order(:name).limit(1).except(:limit).to_a.compact_map(&.name).should eq ["b", "c"]
      Parent.where("name != ?", "a").order(name: :desc).only(:where).count.should eq 2
    end
  end

  describe "to_sql" do
    it "matches raw_sql" do
      relation = Parent.where(name: "a").order(:name).limit(3)

      relation.to_sql.should eq relation.raw_sql
      relation.to_sql.should contain("SELECT")
      relation.to_sql.should contain("LIMIT 3")
    end

    it "runs no query" do
      capture_sql { Parent.where(name: "a").to_sql }.should be_empty
    end
  end

  describe "cache_key" do
    it "is stable for the same query and differs between queries" do
      first = Parent.where(name: "a").cache_key
      first.should eq Parent.where(name: "a").cache_key
      first.should start_with("parents/query-")
      first.should_not eq Parent.where(name: "b").cache_key
      first.should_not eq Parent.where(name: "a").order(:name).cache_key
    end

    it "runs no query" do
      capture_sql { Parent.where(name: "a").cache_key }.should be_empty
    end
  end

  describe "cache_version" do
    it "combines the row count with the newest updated_at in one query" do
      seed_parents(%w(a b))
      relation = Parent.where("name != ?", "zzz")

      version = ""
      statements = capture_sql { version = relation.cache_version }

      statements.size.should eq 1
      statements.first.upcase.should contain("COUNT(*)")
      statements.first.upcase.should contain("MAX(")
      version.should match(/\A2-\d+\z/)

      capture_sql { relation.cache_version }.should be_empty
    end

    it "changes when rows change and is memoized until reset" do
      seed_parents(["a"])
      relation = Parent.where("name != ?", "zzz")

      first = relation.cache_version
      first.should start_with("1-")
      Parent.create(name: "b")
      relation.cache_version.should eq first
      relation.reset.cache_version.should start_with("2-")
      relation.cache_version.should_not eq first
    end

    it "is zero for an empty or none relation" do
      seed_parents(["a"])

      Parent.where(name: "nope").cache_version.should eq "0"
      Parent.where("name != ?", "zzz").none.cache_version.should eq "0"
    end

    it "does not mutate the relation" do
      seed_parents(["a"])
      relation = Parent.where("name != ?", "zzz")
      sql = relation.to_sql

      relation.cache_version

      relation.to_sql.should eq sql
      relation.order_fields.should be_empty
    end
  end
end
