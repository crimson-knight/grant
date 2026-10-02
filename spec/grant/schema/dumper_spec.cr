require "../../support/m04_fixture"
require "../../support/statement_recorder"

private def m04_dump(adapter = M04Fixture.adapter) : String
  text = Grant::Schema::Dumper.dump(adapter, M04Fixture::ONLY_FIXTURE)
  # Enum types belong to the whole database; other specs leave theirs behind.
  text.lines(chomp: false).reject { |line| line.includes?("create_enum") && !line.includes?("m04_") }.join
end

describe Grant::Schema::Dumper do
  before_each { M04Fixture.create! }
  after_all { M04Fixture.drop! }

  describe "dump then load" do
    it "reproduces the schema: columns, indexes, keys, constraints and comments" do
      before = M04Fixture.fingerprint
      snapshot = Grant::Schema::Dumper.new(M04Fixture.adapter, M04Fixture::ONLY_FIXTURE).snapshot
      text = snapshot.to_crystal

      M04Fixture.drop!
      M04Fixture.fingerprint.should be_empty

      Grant::Schema::Loader.new(M04Fixture.adapter).load_snapshot(snapshot)
      M04Fixture.fingerprint.should eq before
      Grant::Schema::Dumper.new(M04Fixture.adapter, M04Fixture::ONLY_FIXTURE).snapshot.to_crystal.should eq text
    end

    it "loads a second time over the existing tables, replacing them" do
      before = M04Fixture.fingerprint
      snapshot = Grant::Schema::Dumper.new(M04Fixture.adapter, M04Fixture::ONLY_FIXTURE).snapshot
      Grant::Schema::Loader.new(M04Fixture.adapter).load_snapshot(snapshot)
      M04Fixture.fingerprint.should eq before
    end
  end

  describe "the dump" do
    it "lists parents before children and leaves cyclic foreign keys for the end" do
      text = m04_dump
      text.index("create_table \"m04_dump_accounts\"").not_nil!.should be < text.index("create_table \"m04_dump_memberships\"").not_nil!
      text.index("create_table \"m04_dump_accounts\"").not_nil!.should be < text.index("create_table \"m04_dump_notes\"").not_nil!
      text.should contain(%(schema.add_foreign_key "m04_dump_cycle_a", "m04_dump_cycle_b", column: "b_id"))
    end

    it "writes primary keys, defaults, limits and leaves default names out" do
      text = m04_dump
      text.should contain(%(schema.create_table "m04_dump_accounts", id: :bigint))
      text.should contain(%(t.string "name", null: false, limit: 80))
      text.should contain(%(primary_key: ["account_id", "member_id"]))
      text.should contain(%(t.index ["member_id"]\n))
      # MySQL has no partial indexes, so the fixture's status index is a plain one there.
      text.should contain(%(t.index ["status"], name: "idx_m04_accounts_status"#{CURRENT_ADAPTER == "mysql" ? "" : ", where: "}))
      text.should contain(%(t.unique_constraint ["name", "status"], name: "uniq_m04_name_status"))
      text.should contain(%(t.check_constraint ))
      text.should contain(%(name: "chk_m04_balance"))
      text.should contain(%(t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade, on_update: :restrict))
      text.should contain(%(t.index ["posted_at"], name: "idx_m04_notes_posted_desc", order: {"posted_at" => "DESC"}))
    end

    it "leaves the tool tables out" do
      M04Fixture.adapter.open { |db| db.exec "CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(255) NOT NULL PRIMARY KEY)" }
      begin
        text = Grant::Schema::Dumper.dump(M04Fixture.adapter)
        text.should_not contain("schema_migrations")
        text.should_not contain("ar_internal_metadata")
      ensure
        M04Fixture.adapter.open { |db| db.exec "DROP TABLE IF EXISTS schema_migrations" }
      end
    end

    it "takes the schema version from schema_migrations" do
      migration = Grant::Schema::SchemaMigration.new(M04Fixture.adapter)
      migration.create_table
      begin
        migration.record(20260101000001_i64)
        migration.record(20260202000002_i64)
        m04_dump.should contain("Grant::Schema.define(version: 20260202000002)")
      ensure
        M04Fixture.adapter.open { |db| db.exec "DROP TABLE IF EXISTS schema_migrations" }
      end
    end

    it "reads the catalog with a fixed number of queries however many tables there are" do
      dumper = Grant::Schema::Dumper.new(M04Fixture.adapter, M04Fixture::ONLY_FIXTURE)
      few = StatementRecorder.statements { dumper.snapshot }.size
      extra = (1..12).map { |number| "m04_dump_extra_#{number}" }
      statements = M04Fixture.statements
      begin
        extra.each { |name| statements.create_table(name) { |t| t.string :title; t.index :title } }
        many = StatementRecorder.statements { dumper.snapshot }.size
        many.should eq few
        few.should be < 20
      ensure
        extra.each { |name| statements.drop_table(name, if_exists: true) }
        M04Fixture.adapter.reset_schema_caches!
      end
    end
  end

  describe "PostgreSQL extras" do
    it "round trips enums, uuid keys, arrays, gin, operator classes, include and exclusion constraints" do
      next unless M04Fixture.pg?
      text = m04_dump
      text.should contain(%(schema.create_enum "m04_mood", ["happy", "sad"], if_not_exists: true))
      text.should contain(%(schema.create_table "m04_dump_pg", id: :uuid, comment: "PostgreSQL only"))
      text.should contain(%(t.column "tags", "text[]"))
      text.should contain(%(using: "gin"))
      text.should contain(%(opclass: {"slug" => "text_pattern_ops"}))
      text.should contain(%(include: ["slug"]))
      text.should contain(%(t.exclusion_constraint "code WITH =", using: "btree", name: "excl_m04_code"))
      text.should contain(%(deferrable: :deferred))
      text.should contain(%(comment: "prefix search"))
      text.should contain(%(t.string "name", null: false, limit: 80, comment: "Display name"))
    end
  end
end

# The dumps the fixture produced, kept as compiled `Grant::Schema.define` blocks
# (the bodies are the dump text, verbatim). Loading them runs the exact code a
# dump file holds, which shows that what the dumper writes is valid DSL and
# creates what it describes.
Grant::Schema.define(version: 0, source: "golden/m04_sqlite.cr") do |schema|
  schema.create_table "m04_dump_accounts", id: :bigint, force: :cascade do |t|
    t.string "name", null: false, limit: 80
    t.decimal "balance", null: false, precision: 12, scale: 2, default_sql: "0"
    t.string "status", null: false, limit: 255, default_sql: "'active'"
    t.text "notes"
    t.boolean "active", null: false, default_sql: "TRUE"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lower(name)"], name: "idx_m04_accounts_lower_name", unique: true
    t.index ["status"], name: "idx_m04_accounts_status", where: "status <> 'closed'"
    t.unique_constraint ["name", "status"], name: "uniq_m04_name_status"
    t.check_constraint "balance >= 0", name: "chk_m04_balance"
  end

  schema.create_table "m04_dump_memberships", id: false, primary_key: ["account_id", "member_id"], force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "member_id", null: false
    t.string "role", null: false, limit: 255, default_sql: "'member'"
    t.index ["member_id"]
    t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade, on_update: :restrict
  end

  schema.create_table "m04_dump_notes", id: :bigint, force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "parent_id"
    t.string "slug", limit: 40
    t.datetime "posted_at"
    t.index ["posted_at"], name: "idx_m04_notes_posted_desc", order: {"posted_at" => "DESC"}
    t.index ["slug", "account_id"], name: "idx_m04_notes_slug_account", unique: true
    t.index ["account_id"]
    t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade
    t.foreign_key "m04_dump_notes", column: "parent_id", on_delete: :set_null
  end

  schema.create_table "m04_dump_cycle_a", id: :bigint, force: :cascade do |t|
    t.bigint "b_id"
  end

  schema.create_table "m04_dump_cycle_b", id: :bigint, force: :cascade do |t|
    t.bigint "a_id"
    t.foreign_key "m04_dump_cycle_a", column: "a_id"
  end

  schema.add_foreign_key "m04_dump_cycle_a", "m04_dump_cycle_b", column: "b_id"
end
Grant::Schema.define(version: 0, source: "golden/m04_pg.cr") do |schema|
  schema.create_enum "m04_mood", ["happy", "sad"], if_not_exists: true

  schema.create_table "m04_dump_accounts", id: :bigint, comment: "Customer accounts", force: :cascade do |t|
    t.string "name", null: false, limit: 80, comment: "Display name"
    t.decimal "balance", null: false, precision: 12, scale: 2, default_sql: "0"
    t.string "status", null: false, default_sql: "'active'::character varying"
    t.text "notes"
    t.boolean "active", null: false, default_sql: "true"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lower(name::text)"], name: "idx_m04_accounts_lower_name", unique: true
    t.index ["status"], name: "idx_m04_accounts_status", where: "((status)::text <> 'closed'::text)"
    t.unique_constraint ["name", "status"], name: "uniq_m04_name_status"
    t.check_constraint "(balance >= (0)::numeric)", name: "chk_m04_balance"
  end

  schema.create_table "m04_dump_memberships", id: false, primary_key: ["account_id", "member_id"], force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "member_id", null: false
    t.string "role", null: false, default_sql: "'member'::character varying"
    t.index ["member_id"]
    t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade, on_update: :restrict, deferrable: :deferred
  end

  schema.create_table "m04_dump_notes", id: :bigint, force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "parent_id"
    t.string "slug", limit: 40
    t.datetime "posted_at", precision: 3
    t.index ["posted_at"], name: "idx_m04_notes_posted_desc", order: {"posted_at" => "DESC"}
    t.index ["slug", "account_id"], name: "idx_m04_notes_slug_account", unique: true
    t.index ["account_id"]
    t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade
    t.foreign_key "m04_dump_notes", column: "parent_id", on_delete: :set_null
  end

  schema.create_table "m04_dump_pg", id: :uuid, comment: "PostgreSQL only", force: :cascade do |t|
    t.column "mood", "m04_mood", null: false, default_sql: "'happy'::m04_mood"
    t.text "code", null: false
    t.string "slug", limit: 30
    t.column "tags", "text[]"
    t.jsonb "data"
    t.index ["code"], name: "idx_m04_pg_code_cover", include: ["slug"]
    t.index ["data"], name: "idx_m04_pg_data", using: "gin"
    t.index ["slug"], name: "idx_m04_pg_slug_ops", opclass: {"slug" => "text_pattern_ops"}, comment: "prefix search"
    t.exclusion_constraint "code WITH =", using: "btree", name: "excl_m04_code"
  end

  schema.create_table "m04_dump_cycle_a", id: :bigint, force: :cascade do |t|
    t.bigint "b_id"
  end

  schema.create_table "m04_dump_cycle_b", id: :bigint, force: :cascade do |t|
    t.bigint "a_id"
    t.foreign_key "m04_dump_cycle_a", column: "a_id"
  end

  schema.add_foreign_key "m04_dump_cycle_a", "m04_dump_cycle_b", column: "b_id"
end
M04_GOLDEN = {
  "sqlite" => <<-'CR',
    # This file is auto-generated from the current state of the database. Instead
    # of editing this file, please use the migrations feature of Grant to change
    # the schema, then dump it again.
    #
    # Require it from the program that runs the database tasks; Grant::Schema.load
    # (or Grant::Tasks::Database#schema_load) creates the schema on a fresh database.

    Grant::Schema.define(version: 0) do |schema|
      schema.create_table "m04_dump_accounts", id: :bigint, force: :cascade do |t|
        t.string "name", null: false, limit: 80
        t.decimal "balance", null: false, precision: 12, scale: 2, default_sql: "0"
        t.string "status", null: false, limit: 255, default_sql: "'active'"
        t.text "notes"
        t.boolean "active", null: false, default_sql: "TRUE"
        t.datetime "created_at", null: false
        t.datetime "updated_at", null: false
        t.index ["lower(name)"], name: "idx_m04_accounts_lower_name", unique: true
        t.index ["status"], name: "idx_m04_accounts_status", where: "status <> 'closed'"
        t.unique_constraint ["name", "status"], name: "uniq_m04_name_status"
        t.check_constraint "balance >= 0", name: "chk_m04_balance"
      end

      schema.create_table "m04_dump_memberships", id: false, primary_key: ["account_id", "member_id"], force: :cascade do |t|
        t.bigint "account_id", null: false
        t.bigint "member_id", null: false
        t.string "role", null: false, limit: 255, default_sql: "'member'"
        t.index ["member_id"]
        t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade, on_update: :restrict
      end

      schema.create_table "m04_dump_notes", id: :bigint, force: :cascade do |t|
        t.bigint "account_id"
        t.bigint "parent_id"
        t.string "slug", limit: 40
        t.datetime "posted_at"
        t.index ["posted_at"], name: "idx_m04_notes_posted_desc", order: {"posted_at" => "DESC"}
        t.index ["slug", "account_id"], name: "idx_m04_notes_slug_account", unique: true
        t.index ["account_id"]
        t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade
        t.foreign_key "m04_dump_notes", column: "parent_id", on_delete: :set_null
      end

      schema.create_table "m04_dump_cycle_a", id: :bigint, force: :cascade do |t|
        t.bigint "b_id"
      end

      schema.create_table "m04_dump_cycle_b", id: :bigint, force: :cascade do |t|
        t.bigint "a_id"
        t.foreign_key "m04_dump_cycle_a", column: "a_id"
      end

      schema.add_foreign_key "m04_dump_cycle_a", "m04_dump_cycle_b", column: "b_id"
    end
    CR
  "pg" => <<-'CR',
    # This file is auto-generated from the current state of the database. Instead
    # of editing this file, please use the migrations feature of Grant to change
    # the schema, then dump it again.
    #
    # Require it from the program that runs the database tasks; Grant::Schema.load
    # (or Grant::Tasks::Database#schema_load) creates the schema on a fresh database.

    Grant::Schema.define(version: 0) do |schema|
      schema.create_enum "m04_mood", ["happy", "sad"], if_not_exists: true

      schema.create_table "m04_dump_accounts", id: :bigint, comment: "Customer accounts", force: :cascade do |t|
        t.string "name", null: false, limit: 80, comment: "Display name"
        t.decimal "balance", null: false, precision: 12, scale: 2, default_sql: "0"
        t.string "status", null: false, default_sql: "'active'::character varying"
        t.text "notes"
        t.boolean "active", null: false, default_sql: "true"
        t.datetime "created_at", null: false
        t.datetime "updated_at", null: false
        t.index ["lower(name::text)"], name: "idx_m04_accounts_lower_name", unique: true
        t.index ["status"], name: "idx_m04_accounts_status", where: "((status)::text <> 'closed'::text)"
        t.unique_constraint ["name", "status"], name: "uniq_m04_name_status"
        t.check_constraint "(balance >= (0)::numeric)", name: "chk_m04_balance"
      end

      schema.create_table "m04_dump_memberships", id: false, primary_key: ["account_id", "member_id"], force: :cascade do |t|
        t.bigint "account_id", null: false
        t.bigint "member_id", null: false
        t.string "role", null: false, default_sql: "'member'::character varying"
        t.index ["member_id"]
        t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade, on_update: :restrict, deferrable: :deferred
      end

      schema.create_table "m04_dump_notes", id: :bigint, force: :cascade do |t|
        t.bigint "account_id"
        t.bigint "parent_id"
        t.string "slug", limit: 40
        t.datetime "posted_at", precision: 3
        t.index ["posted_at"], name: "idx_m04_notes_posted_desc", order: {"posted_at" => "DESC"}
        t.index ["slug", "account_id"], name: "idx_m04_notes_slug_account", unique: true
        t.index ["account_id"]
        t.foreign_key "m04_dump_accounts", column: "account_id", on_delete: :cascade
        t.foreign_key "m04_dump_notes", column: "parent_id", on_delete: :set_null
      end

      schema.create_table "m04_dump_pg", id: :uuid, comment: "PostgreSQL only", force: :cascade do |t|
        t.column "mood", "m04_mood", null: false, default_sql: "'happy'::m04_mood"
        t.text "code", null: false
        t.string "slug", limit: 30
        t.column "tags", "text[]"
        t.jsonb "data"
        t.index ["code"], name: "idx_m04_pg_code_cover", include: ["slug"]
        t.index ["data"], name: "idx_m04_pg_data", using: "gin"
        t.index ["slug"], name: "idx_m04_pg_slug_ops", opclass: {"slug" => "text_pattern_ops"}, comment: "prefix search"
        t.exclusion_constraint "code WITH =", using: "btree", name: "excl_m04_code"
      end

      schema.create_table "m04_dump_cycle_a", id: :bigint, force: :cascade do |t|
        t.bigint "b_id"
      end

      schema.create_table "m04_dump_cycle_b", id: :bigint, force: :cascade do |t|
        t.bigint "a_id"
        t.foreign_key "m04_dump_cycle_a", column: "a_id"
      end

      schema.add_foreign_key "m04_dump_cycle_a", "m04_dump_cycle_b", column: "b_id"
    end
    CR
}

describe "a dump file" do
  before_each { M04Fixture.create! }
  after_all { M04Fixture.drop! }

  it "is the text the dumper writes" do
    text = Grant::Schema::Dumper.dump(M04Fixture.adapter, M04Fixture::ONLY_FIXTURE)
    text = text.lines(chomp: false).reject { |line| line.includes?("create_enum") && !line.includes?("m04_") }.join
    text.should eq M04_GOLDEN[CURRENT_ADAPTER] + "\n"
  end

  it "loads from its compiled Grant::Schema.define block by path and recreates the schema" do
    before = M04Fixture.fingerprint
    M04Fixture.drop!

    path = "golden/m04_#{CURRENT_ADAPTER}.cr"
    Grant::Schema.definition_for(path).should_not be_nil
    Grant::Schema.load(M04Fixture.adapter, path).should eq 0
    M04Fixture.fingerprint.should eq before
  end

  it "says so when the file was never compiled in" do
    expect_raises(Grant::Schema::SchemaFileMissing, /m04_none/) { Grant::Schema.load(M04Fixture.adapter, "db/m04_none.cr") }
    expect_raises(Grant::Schema::SchemaNotCompiled) { Grant::Schema.load(M04Fixture.adapter, __FILE__) }
  end
end
