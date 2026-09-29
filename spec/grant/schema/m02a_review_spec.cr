require "../../support/schema_fixture"
require "../../support/test_connection"

enum M02aReviewLevel
  Low
  High
end

class M02aReviewEnumRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02a_review_enum_rows

  column id : Int64, primary: true
  column level_as_int : M02aReviewLevel?, converter: Grant::Converters::Enum(M02aReviewLevel, Int64)
  column level_as_text : M02aReviewLevel?, converter: Grant::Converters::Enum(M02aReviewLevel, String)
end

describe "M02a review fixes" do
  describe "enum columns in the migrator" do
    it "maps the column to the converter's storage type" do
      TestConnection.ensure_registered
      sql = M02aReviewEnumRow.migrator.create_sql
      q = CURRENT_ADAPTER == "mysql" ? "`" : "\""
      int_type = CURRENT_ADAPTER == "sqlite" ? "INTEGER" : "BIGINT"
      text_type = CURRENT_ADAPTER == "pg" ? "TEXT" : "VARCHAR(255)"
      sql.should contain "#{q}level_as_int#{q} #{int_type}"
      sql.should contain "#{q}level_as_text#{q} #{text_type}"
    end

    it "round trips an integer-stored enum" do
      TestConnection.ensure_registered
      M02aReviewEnumRow.migrator.drop_and_create
      row = M02aReviewEnumRow.new
      row.level_as_int = M02aReviewLevel::High
      row.level_as_text = M02aReviewLevel::Low
      row.save!
      found = M02aReviewEnumRow.find!(row.id)
      found.level_as_int.should eq M02aReviewLevel::High
      found.level_as_text.should eq M02aReviewLevel::Low
      M02aReviewEnumRow.migrator.drop
    end
  end

  describe "TableDefinition#column" do
    it "raises InvalidDefinition for an unknown symbol type" do
      expect_raises(Grant::Schema::InvalidDefinition, /Unknown column type :nope/) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02a_review_t) do |t|
          t.column :x, :nope
        end
      end
    end

    it "accepts a symbol kind" do
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).create_table_statements(:m02a_review_t, id: false) do |t|
        t.column :n, :smallint
      end.first.should contain "`n` SMALLINT"
    end
  end
end
