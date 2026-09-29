require "../../support/schema_fixture"

describe "Model.verify_schema" do
  before_all { SchemaFixture.create! }
  after_all { SchemaFixture.drop! }

  it "finds no drift in a model that matches its table" do
    M01Author.verify_schema.should be_empty
    M01Author.verify_schema!
    M01Author.verify_schema(strict: true).should be_empty
  end

  it "reports a missing table" do
    drift = M01Ghost.verify_schema
    drift.map(&.kind).should eq [Grant::Schema::Drift::Kind::MissingTable]
    M01Ghost.table_exists?.should be_false
  end

  it "reports missing columns and type mismatches" do
    drift = M01DriftedAuthor.verify_schema
    kinds = drift.map { |entry| {entry.kind, entry.column_name} }
    kinds.should contain({Grant::Schema::Drift::Kind::MissingColumn, "nickname"})
    kinds.should contain({Grant::Schema::Drift::Kind::TypeMismatch, "email"})
    kinds.size.should eq 2
  end

  it "raises DriftError naming every difference" do
    error = expect_raises(Grant::Schema::DriftError, /nickname.*email|email.*nickname/) do
      M01DriftedAuthor.verify_schema!
    end
    error.model_name.should eq "M01DriftedAuthor"
    error.drift.size.should eq 2
  end

  it "reports a primary key that differs from the table" do
    drift = M01Membership.verify_schema
    drift.map(&.kind).should eq [Grant::Schema::Drift::Kind::PrimaryKeyMismatch]
  end

  it "reports undeclared and nullable columns only when strict" do
    M01PartialAuthor.verify_schema.should be_empty

    drift = M01PartialAuthor.verify_schema(strict: true)
    drift.select(&.kind.undeclared_column?).map(&.column_name).should eq ["active", "created_at"]
    drift.select(&.kind.nullable_column?).map(&.column_name).should eq ["bio"]
  end

  it "exposes the table's columns, indexes and keys on the model" do
    M01Author.column_exists?(:email).should be_true
    M01Author.column_exists?(:nope).should be_false
    M01Author.database_columns.map(&.name).should contain("bio")
    M01Author.database_indexes.should_not be_nil
    M01Membership.database_foreign_keys.first.to_table.should eq "m01_authors"
  end
end
