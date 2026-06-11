require "../../spec_helper"

# Regression specs for Bug 5: select(*columns) was silently ignored.
# The assembler's field_list always returned Model.fields; @query.select_columns
# was never used in the SELECT list for model-loading queries.
#
# Hydration analysis: Grant::Columns#from_rs reads by column name via
# `result.column_names.each { |col| case col ... }`, so projecting fewer
# columns is safe — unselected columns remain nil (their Crystal default).
describe "select projection" do
  before_each do
    Review.clear
  end

  describe "generated SQL" do
    it "includes only selected columns in SELECT clause when .select(*cols) is called" do
      sql = Review.where.select(:id, :name).raw_sql
      select_clause = sql.downcase.split("from").first
      select_clause.should contain("id")
      select_clause.should contain("name")
      select_clause.should_not contain("downvotes")
      select_clause.should_not contain("upvotes")
      select_clause.should_not contain("sentiment")
    end

    it "raw_sql reflects single-column projection" do
      sql = Review.where.select(:name).raw_sql
      select_clause = sql.downcase.split("from").first
      select_clause.should contain("name")
      select_clause.should_not contain("downvotes")
      select_clause.should_not contain("id")
    end

    it "raw_sql uses all model fields when no .select(*cols) is called" do
      sql = Review.where.raw_sql
      select_clause = sql.downcase.split("from").first
      select_clause.should contain("id")
      select_clause.should contain("name")
      select_clause.should contain("downvotes")
    end

    it "reselect replaces the column list in SQL" do
      sql = Review.where.select(:id, :name).reselect(:id, :downvotes).raw_sql
      select_clause = sql.downcase.split("from").first
      select_clause.should contain("id")
      select_clause.should contain("downvotes")
      select_clause.should_not contain("name")
    end
  end

  describe "real sqlite rows" do
    it "hydrates selected columns and leaves unselected columns nil" do
      Review.create(name: "projection_test", downvotes: 42, upvotes: 7_i64)

      rows = Review.where(name: "projection_test").select(:id, :name).select
      rows.size.should eq 1
      row = rows.first

      # Selected columns must be populated
      row.id.should_not be_nil
      row.name.should eq "projection_test"

      # Unselected columns must be nil (hydration is by column name; absent
      # columns leave the ivar at its Crystal default, which is nil for nullable types)
      row.downvotes.should be_nil
      row.upvotes.should be_nil
    end

    it "single-column projection returns correct value" do
      Review.create(name: "solo", downvotes: 99)

      rows = Review.where(name: "solo").select(:downvotes).select
      rows.size.should eq 1
      rows.first.downvotes.should eq 99
      rows.first.name.should be_nil
      rows.first.id.should be_nil
    end

    it "reselect overrides an earlier select for hydration" do
      Review.create(name: "rr", downvotes: 11, upvotes: 22_i64)

      rows = Review.where(name: "rr").select(:name).reselect(:downvotes).select
      rows.size.should eq 1
      row = rows.first
      row.downvotes.should eq 11
      row.name.should be_nil
    end

    it "chaining .select(*cols) with .where still projects correctly" do
      Review.create(name: "a", downvotes: 1)
      Review.create(name: "b", downvotes: 2)
      Review.create(name: "c", downvotes: 3)

      rows = Review.where.select(:id, :downvotes).where.gteq(:downvotes, 2).select
      rows.size.should eq 2
      rows.each do |row|
        row.id.should_not be_nil
        row.downvotes.should_not be_nil
        row.name.should be_nil
      end
    end
  end
end
