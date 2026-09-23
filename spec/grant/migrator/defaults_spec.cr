require "../luna_t4_spec_helper"

class MigratorDefaultLiteralRow < Grant::Base
  connection {{ env("CURRENT_ADAPTER").id }}
  table migrator_default_literal_rows

  column id : Int64, primary: true
  column status : String = "it's ready"
  column retry_count : Int32 = 3
  column is_enabled : Bool = true
  column is_archived : Bool = false
  column optional_note : String? = nil
end

describe "Grant::Migrator column defaults" do
  before_each do
    GrantLunaT4SpecHelper.ensure_test_connection
    MigratorDefaultLiteralRow.migrator.drop_and_create
  end

  it "persists Crystal literal defaults for direct SQL inserts" do
    MigratorDefaultLiteralRow.exec("INSERT INTO migrator_default_literal_rows DEFAULT VALUES")

    row = MigratorDefaultLiteralRow.first.not_nil!
    row.status.should eq("it's ready")
    row.retry_count.should eq(3)
    row.is_enabled.should be_true
    row.is_archived.should be_false
    row.optional_note.should be_nil
  end

  it "emits escaped string and scalar defaults in the create SQL" do
    create_sql = MigratorDefaultLiteralRow.migrator.create_sql

    create_sql.should contain("DEFAULT 'it''s ready'")
    create_sql.should contain("DEFAULT 3")
    create_sql.should contain("DEFAULT TRUE")
    create_sql.should contain("DEFAULT FALSE")
    create_sql.should contain("DEFAULT NULL")
  end
end
