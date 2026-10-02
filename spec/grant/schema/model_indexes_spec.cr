require "../../support/schema_fixture"
require "../../support/test_connection"

class M02bIndexedRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02b_indexed_rows

  column id : Int64, primary: true
  column email : String, limit: 100
  column last_name : String?, limit: 50
  column first_name : String?, limit: 50

  index :email, unique: true
  index [:last_name, :first_name], name: "m02b_indexed_rows_names"
end

describe "Model index declarations on #{CURRENT_ADAPTER}" do
  before_each { TestConnection.ensure_registered }
  after_all { M02bIndexedRow.migrator.drop }

  it "adds the declared indexes to the creation statements" do
    statements = M02bIndexedRow.migrator.create_statements
    statements.size.should eq 3
    statements.any?(&.includes?("m02b_indexed_rows_names")).should be_true
    statements.any?(&.starts_with?("CREATE UNIQUE INDEX")).should be_true
  end

  it "creates the table with its indexes and enforces the unique one" do
    M02bIndexedRow.migrator.drop_and_create
    schema = M02bIndexedRow.adapter.schema
    schema.index_exists?(:m02b_indexed_rows, ["email"] of String | Symbol, unique: true).should be_true
    schema.index_exists?(:m02b_indexed_rows, name: "m02b_indexed_rows_names").should be_true
    M02bIndexedRow.create!(email: "a@x")
    expect_raises(Exception) { M02bIndexedRow.create!(email: "a@x") }
  end
end
