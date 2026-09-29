require "../../support/schema_fixture"
require "../../support/test_connection"

class M02aOptionRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02a_option_rows

  column id : Int64, primary: true
  column happened : Time?, precision: 3
  column code : String, limit: 20, collation: {{ {"pg" => "C", "mysql" => "utf8mb4_bin"}[env("CURRENT_ADAPTER") || "sqlite"] || "NOCASE" }}, comment: "Public code"
  column note : String, null: true
end

describe "Grant::Migrator create options on #{CURRENT_ADAPTER}" do
  before_each { TestConnection.ensure_registered }
  after_all { M02aOptionRow.migrator.drop }

  it "adds IF NOT EXISTS and TEMPORARY" do
    sql = M02aOptionRow.migrator.create_sql(if_not_exists: true, temporary: true)
    sql.should start_with "CREATE TEMPORARY TABLE IF NOT EXISTS "
  end

  it "applies precision, scale, limit, collation, comment and null:" do
    sql = M02aOptionRow.migrator.create_sql(comment: "Rows")
    case CURRENT_ADAPTER
    when "pg"
      sql.should contain %("happened" TIMESTAMP(3))
      sql.should contain %("code" VARCHAR(20) COLLATE "C" NOT NULL)
      M02aOptionRow.migrator.create_statements(comment: "Rows").tap do |statements|
        statements.size.should eq 3
        statements[1].should eq %(COMMENT ON TABLE "m02a_option_rows" IS 'Rows')
        statements[2].should eq %(COMMENT ON COLUMN "m02a_option_rows"."code" IS 'Public code')
      end
    when "mysql"
      sql.should contain "`happened` TIMESTAMP(3)"
      sql.should contain "`code` VARCHAR(20) COLLATE utf8mb4_bin NOT NULL COMMENT 'Public code'"
      sql.should contain ") COMMENT='Rows'"
    else
      sql.should contain %("happened" TIMESTAMP)
      sql.should contain %("code" VARCHAR(20) COLLATE NOCASE NOT NULL)
      M02aOptionRow.migrator.create_statements(comment: "Rows").size.should eq 1
    end
    sql.should contain %(#{CURRENT_ADAPTER == "mysql" ? "`note`" : "\"note\""} #{CURRENT_ADAPTER == "pg" ? "TEXT" : "VARCHAR(255)"}\n)
  end

  it "creates idempotently and drops with options" do
    migrator = M02aOptionRow.migrator
    migrator.drop
    migrator.create
    expect_raises(Grant::ErrorBase) { migrator.create }
    migrator.create(if_not_exists: true)
    migrator.drop_sql.should eq %(DROP TABLE IF EXISTS #{CURRENT_ADAPTER == "mysql" ? "`m02a_option_rows`" : "\"m02a_option_rows\""};)
    migrator.drop_sql(if_exists: false).should start_with "DROP TABLE #{CURRENT_ADAPTER == "mysql" ? "`" : "\""}"
    migrator.drop_sql(cascade: true).ends_with?(" CASCADE;").should eq(CURRENT_ADAPTER == "pg")
    migrator.drop
    migrator.drop
  end
end
