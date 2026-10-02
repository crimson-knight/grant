require "../../support/schema_fixture"

describe "M02b check, unique and exclusion constraints" do
  describe "SQL per dialect" do
    it "adds check constraints, NOT VALID on PostgreSQL only" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_check_constraint_statements(:products, "price > 0", name: "price_check", validate: false)
        .should eq ["ALTER TABLE \"products\" ADD CONSTRAINT \"price_check\" CHECK (price > 0) NOT VALID"]
      pg.validate_check_constraint_statements(:products, name: "price_check").should eq ["ALTER TABLE \"products\" VALIDATE CONSTRAINT \"price_check\""]
      my = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql)
      my.add_check_constraint_statements(:products, "price > 0", name: "price_check", validate: false)
        .should eq ["ALTER TABLE `products` ADD CONSTRAINT `price_check` CHECK (price > 0)"]
      my.remove_check_constraint_statements(:products, name: "price_check").should eq ["ALTER TABLE `products` DROP CHECK `price_check`"]
      pg.add_check_constraint_statements(:products, "price > 0").first.should match(/CONSTRAINT "chk_products_[0-9a-f]{8}" CHECK/)
    end

    it "adds and drops unique constraints per dialect" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_unique_constraint_statements(:sections, [:position, :page_id], deferrable: :immediate)
        .should eq ["ALTER TABLE \"sections\" ADD CONSTRAINT \"uniq_sections_position_page_id\" UNIQUE (\"position\", \"page_id\") DEFERRABLE INITIALLY IMMEDIATE"]
      pg.add_unique_constraint_statements(:sections, :position, name: "u", using_index: "idx")
        .should eq ["ALTER TABLE \"sections\" ADD CONSTRAINT \"u\" UNIQUE USING INDEX \"idx\""]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).remove_unique_constraint_statements(:sections, name: "u")
        .should eq ["ALTER TABLE `sections` DROP INDEX `u`"]
      pg.remove_unique_constraint_statements(:sections, name: "u").should eq ["ALTER TABLE \"sections\" DROP CONSTRAINT \"u\""]
      expect_raises(Grant::Schema::UnsupportedOperation) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).add_unique_constraint_statements(:s, :a, deferrable: true)
      end
    end

    it "emits exclusion constraints on PostgreSQL only" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_exclusion_constraint_statements(:rooms, "tsrange(starts_at, ends_at) WITH &&", using: :gist, name: "no_overlap")
        .should eq ["ALTER TABLE \"rooms\" ADD CONSTRAINT \"no_overlap\" EXCLUDE USING gist (tsrange(starts_at, ends_at) WITH &&)"]
      expect_raises(Grant::Schema::UnsupportedOperation) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).add_exclusion_constraint_statements(:rooms, "x WITH &&")
      end
    end

    it "declares constraints in create_table" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02b_c) do |t|
        t.integer :qty
        t.check_constraint "qty >= 0", name: "qty_positive"
        t.unique_constraint :qty, name: "qty_unique"
      end.first
      sql.should contain "CONSTRAINT \"qty_unique\" UNIQUE (\"qty\")"
      sql.should contain "CONSTRAINT \"qty_positive\" CHECK (qty >= 0)"
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_ck, if_exists: true)
      statements.create_table(:m02b_ck) do |t|
        t.integer :price
        t.integer :page_id
        t.integer :position
      end
      SchemaFixture.exec "INSERT INTO m02b_ck (price, page_id, position) VALUES (5, 1, 1)"
    end
    after_each { statements.drop_table(:m02b_ck, if_exists: true) }

    it "adds a check constraint, enforces it, and reads it back" do
      statements.add_check_constraint(:m02b_ck, "price > 0", name: "m02b_price_check")
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_ck (price) VALUES (0)" }
      SchemaFixture.exec "INSERT INTO m02b_ck (price) VALUES (1)"
      info = schema.check_constraints(:m02b_ck).find! { |check| check.name == "m02b_price_check" }
      info.expression.should contain "price"
      info.validated?.should be_true
    end

    it "keeps existing rows when adding a check on SQLite and the data otherwise" do
      statements.add_check_constraint(:m02b_ck, "price > 0", name: "m02b_price_check")
      SchemaFixture.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM m02b_ck").should eq 1 }
    end

    it "removes a check constraint by name and by expression" do
      statements.add_check_constraint(:m02b_ck, "price > 0", name: "m02b_price_check")
      statements.remove_check_constraint(:m02b_ck, name: "m02b_price_check")
      schema.check_constraints(:m02b_ck).should be_empty
      SchemaFixture.exec "INSERT INTO m02b_ck (price) VALUES (0)"
      SchemaFixture.exec "DELETE FROM m02b_ck WHERE price = 0"
      statements.add_check_constraint(:m02b_ck, "price >= 0")
      statements.remove_check_constraint(:m02b_ck, "price >= 0")
      schema.check_constraints(:m02b_ck).should be_empty
    end

    it "adds NOT VALID then validates a check on PostgreSQL" do
      next unless CURRENT_ADAPTER == "pg"
      SchemaFixture.exec "INSERT INTO m02b_ck (price) VALUES (-1)"
      statements.add_check_constraint(:m02b_ck, "price >= 0", name: "m02b_nv", validate: false)
      schema.check_constraints(:m02b_ck).find! { |check| check.name == "m02b_nv" }.validated?.should be_false
      expect_raises(Exception) { statements.validate_check_constraint(:m02b_ck, name: "m02b_nv") }
      SchemaFixture.exec "DELETE FROM m02b_ck WHERE price < 0"
      statements.validate_check_constraint(:m02b_ck, name: "m02b_nv")
      schema.check_constraints(:m02b_ck).find! { |check| check.name == "m02b_nv" }.validated?.should be_true
    end

    it "adds a unique constraint, enforces it, reads it back, and removes it" do
      statements.add_unique_constraint(:m02b_ck, [:position, :page_id], name: "m02b_uniq")
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_ck (page_id, position) VALUES (1, 1)" }
      schema.unique_constraints(:m02b_ck).map(&.columns).should eq [["position", "page_id"]]
      statements.remove_unique_constraint(:m02b_ck, name: "m02b_uniq")
      schema.unique_constraints(:m02b_ck).should be_empty
      SchemaFixture.exec "INSERT INTO m02b_ck (page_id, position) VALUES (1, 1)"
    end

    it "removes a unique constraint by its columns" do
      statements.add_unique_constraint(:m02b_ck, :position)
      statements.remove_unique_constraint(:m02b_ck, :position)
      schema.unique_constraints(:m02b_ck).should be_empty
    end

    it "promotes a concurrently built index to a unique constraint on PostgreSQL" do
      next unless CURRENT_ADAPTER == "pg"
      statements.add_index(:m02b_ck, :position, unique: true, name: "m02b_pos_idx", algorithm: :concurrently)
      statements.add_unique_constraint(:m02b_ck, :position, name: "m02b_pos_uniq", using_index: "m02b_pos_idx")
      schema.unique_constraints(:m02b_ck).map(&.name).should eq ["m02b_pos_uniq"]
    end

    it "adds an exclusion constraint on PostgreSQL" do
      next unless CURRENT_ADAPTER == "pg"
      statements.drop_table(:m02b_rooms, if_exists: true)
      statements.create_table(:m02b_rooms) { |t| t.datetime :starts_at; t.datetime :ends_at }
      statements.add_exclusion_constraint(:m02b_rooms, "tsrange(starts_at, ends_at) WITH &&", using: :gist, name: "m02b_no_overlap")
      SchemaFixture.exec "INSERT INTO m02b_rooms (starts_at, ends_at) VALUES ('2026-01-01 10:00', '2026-01-01 12:00')"
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_rooms (starts_at, ends_at) VALUES ('2026-01-01 11:00', '2026-01-01 13:00')" }
      schema.exclusion_constraints(:m02b_rooms).map(&.name).should eq ["m02b_no_overlap"]
      statements.remove_exclusion_constraint(:m02b_rooms, name: "m02b_no_overlap")
      SchemaFixture.exec "INSERT INTO m02b_rooms (starts_at, ends_at) VALUES ('2026-01-01 11:00', '2026-01-01 13:00')"
      statements.drop_table(:m02b_rooms)
    end
  end
end
