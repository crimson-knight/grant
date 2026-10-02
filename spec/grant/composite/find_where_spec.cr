require "../../spec_helper"
require "../../support/composite_sql_recorder"

class CkFindItem < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_find_items

  column shop_id : Int64, primary: true, auto: false
  column order_id : Int64, primary: true, auto: false
  column label : String?
  column note : String?
  composite_primary_key shop_id, order_id
end

class CkFindPlain < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table ck_find_plains

  column id : Int64, primary: true
  column name : String?
end

describe "composite key finders and tuple conditions" do
  before_all do
    CkFindItem.migrator.drop_and_create
    CkFindPlain.migrator.drop_and_create
  end

  before_each do
    CkFindItem.clear
    CkFindPlain.clear
    (1_i64..3_i64).each do |shop|
      (1_i64..3_i64).each do |order|
        CkFindItem.create!(shop_id: shop, order_id: order, label: "s#{shop}o#{order}")
      end
    end
  end

  describe "find" do
    it "finds one row by a key tuple" do
      CkFindItem.find({2_i64, 3_i64}).not_nil!.label.should eq "s2o3"
      CkFindItem.find({2_i64, 9_i64}).should be_nil
    end

    it "finds one row by a named tuple, in any order, and by keywords" do
      CkFindItem.find({order_id: 3_i64, shop_id: 2_i64}).not_nil!.label.should eq "s2o3"
      CkFindItem.find(shop_id: 1_i64, order_id: 1_i64).not_nil!.label.should eq "s1o1"
    end

    it "find! raises NotFound naming the key" do
      expect_raises(Grant::Querying::NotFound, /shop_id, order_id/) { CkFindItem.find!({9_i64, 9_i64}) }
      expect_raises(Grant::Querying::NotFound) { CkFindItem.find!(shop_id: 9_i64, order_id: 9_i64) }
      CkFindItem.find!({1_i64, 2_i64}).label.should eq "s1o2"
    end

    it "finds an array of tuples in the given order with one query, skipping missing keys" do
      keys = [{3_i64, 1_i64}, {1_i64, 1_i64}, {9_i64, 9_i64}, {2_i64, 2_i64}]
      found = [] of CkFindItem
      statements = capture_statements { found = CkFindItem.find(keys) }
      found.map(&.label).should eq ["s3o1", "s1o1", "s2o2"]
      statements.select(&.starts_with?("SELECT")).size.should eq 1
    end

    it "find! with an array raises naming every missing key" do
      expect_raises(Grant::Querying::NotFound, /9, 9/) do
        CkFindItem.find!([{1_i64, 1_i64}, {9_i64, 9_i64}])
      end
      CkFindItem.find!([{1_i64, 1_i64}, {2_i64, 2_i64}]).size.should eq 2
    end

    it "queries long key lists in chunks of in_clause_limit" do
      keys = (1_i64..3_i64).flat_map { |shop| (1_i64..3_i64).map { |order| {shop, order} } }
      original = Grant.settings.in_clause_limit
      begin
        Grant.settings.in_clause_limit = 4
        found = [] of CkFindItem
        statements = capture_statements { found = CkFindItem.find(keys) }
        found.size.should eq 9
        statements.select(&.starts_with?("SELECT")).size.should eq 3
      ensure
        Grant.settings.in_clause_limit = original
      end
    end

    it "exists? takes a tuple, a named tuple or keywords" do
      CkFindItem.exists?({1_i64, 1_i64}).should be_true
      CkFindItem.exists?({1_i64, 7_i64}).should be_false
      CkFindItem.exists?({shop_id: 2_i64, order_id: 2_i64}).should be_true
      CkFindItem.exists?(shop_id: 8_i64, order_id: 2_i64).should be_false
    end

    it "rejects a key of the wrong size or with a missing column" do
      expect_raises(ArgumentError, /keyed by/) { CkFindItem.find({1_i64}) }
      expect_raises(ArgumentError, /Missing key column|keyed by/) { CkFindItem.find({shop_id: 1_i64}) }
    end
  end

  describe "row-value IN" do
    it "writes (a, b) IN (...) and returns the matching rows" do
      relation = CkFindItem.where_tuples([:shop_id, :order_id], [{1_i64, 1_i64}, {2_i64, 3_i64}])
      sql = ""
      rows = [] of CkFindItem
      statements = capture_statements { rows = relation.select }
      sql = statements.find!(&.starts_with?("SELECT"))
      rows.map(&.label.to_s).sort!.should eq ["s1o1", "s2o3"]

      predicate = where_part(sql)
      predicate.should contain("IN")
      predicate.should_not contain("OR")
      if CURRENT_ADAPTER == "sqlite"
        predicate.should contain("VALUES")
      else
        predicate.should_not contain("VALUES")
      end
    end

    it "keeps only rows outside the list with where_not_tuples" do
      rows = CkFindItem.where_not_tuples([:shop_id, :order_id], [{1_i64, 1_i64}, {2_i64, 3_i64}]).select
      rows.size.should eq 7
      rows.map(&.label).should_not contain("s1o1")
    end

    it "composes with other conditions and an empty list matches nothing" do
      CkFindItem.where(shop_id: 1_i64).where_tuples([:shop_id, :order_id], [{1_i64, 1_i64}, {2_i64, 2_i64}]).select.map(&.label).should eq ["s1o1"]
      CkFindItem.where_tuples([:shop_id, :order_id], [] of Tuple(Int64, Int64)).select.should be_empty
    end

    it "takes where(id: [[a, b], ...]) and where(id: {a, b}) on a composite key model" do
      CkFindItem.where(id: [[1_i64, 2_i64], [3_i64, 3_i64]]).select.map(&.label.to_s).sort!.should eq ["s1o2", "s3o3"]
      CkFindItem.where(id: {2_i64, 1_i64}).select.map(&.label).should eq ["s2o1"]
    end

    it "degrades to a plain IN for one column" do
      CkFindItem.where_tuples([:shop_id], [{1_i64}, {2_i64}]).count.should eq 6
    end

    it "raises for a tuple of the wrong size or an unknown column" do
      expect_raises(ArgumentError, /values for 2 columns/) do
        CkFindItem.where_tuples([:shop_id, :order_id], [{1_i64}])
      end
      expect_raises(ArgumentError, /Unknown query field/) do
        CkFindItem.where_tuples([:shop_id, :nope], [{1_i64, 2_i64}]).select
      end
    end

    it "refuses more tuples than in_clause_limit in one predicate" do
      original = Grant.settings.in_clause_limit
      begin
        Grant.settings.in_clause_limit = 2
        expect_raises(ArgumentError, /in_clause_limit/) do
          CkFindItem.where_tuples([:shop_id, :order_id], [{1_i64, 1_i64}, {1_i64, 2_i64}, {1_i64, 3_i64}])
        end
      ensure
        Grant.settings.in_clause_limit = original
      end
    end
  end

  describe "OR expansion" do
    it "is used on request and writes (a = ? AND b = ?) OR (...)" do
      relation = CkFindItem.where_tuples([:shop_id, :order_id], [{1_i64, 1_i64}, {2_i64, 3_i64}], :or_expansion)
      rows = [] of CkFindItem
      statements = capture_statements { rows = relation.select }
      rows.map(&.label.to_s).sort!.should eq ["s1o1", "s2o3"]
      predicate = where_part(statements.find!(&.starts_with?("SELECT")))
      predicate.should contain(" OR ")
      predicate.should_not contain("VALUES")
    end

    it "is chosen automatically when a tuple holds NULL, matching with IS NULL" do
      CkFindItem.where(shop_id: 1_i64, order_id: 1_i64).update_all(note: "x")
      relation = CkFindItem.where_tuples([:shop_id, :note], [{1_i64, "x"}, {2_i64, nil}])
      rows = [] of CkFindItem
      statements = capture_statements { rows = relation.select }
      predicate = where_part(statements.find!(&.starts_with?("SELECT")))
      predicate.should contain("IS NULL")
      rows.map(&.label.to_s).sort!.should eq ["s1o1", "s2o1", "s2o2", "s2o3"]
    end

    it "is capped so the statement cannot balloon" do
      tuples = (1..(Grant::Query::TupleConditions::OR_EXPANSION_LIMIT + 1)).map { |index| {1_i64, index.to_i64} }
      original = Grant.settings.in_clause_limit
      begin
        Grant.settings.in_clause_limit = 10_000
        expect_raises(ArgumentError, /OR expansion limit/) do
          CkFindItem.where_tuples([:shop_id, :order_id], tuples, :or_expansion)
        end
        # The row-value form has no such cap.
        CkFindItem.where_tuples([:shop_id, :order_id], tuples, :row_value).select.size.should eq 3
      ensure
        Grant.settings.in_clause_limit = original
      end
    end
  end

  describe "single-key models" do
    it "keep their behavior" do
      CkFindPlain.create!(id: 1_i64, name: "a")
      CkFindPlain.create!(id: 2_i64, name: "b")
      CkFindPlain.find(1_i64).not_nil!.name.should eq "a"
      CkFindPlain.where(id: [1_i64, 2_i64]).count.should eq 2
      CkFindPlain.where_tuples([:id], [{2_i64}]).select.map(&.name).should eq ["b"]
    end
  end
end
