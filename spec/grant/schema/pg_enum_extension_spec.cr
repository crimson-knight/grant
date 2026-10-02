require "../../support/schema_fixture"

describe "M02b PostgreSQL enums, extensions and column types" do
  describe "SQL" do
    pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)

    it "creates, alters and drops enums" do
      pg.create_enum_statements(:status, %w[draft published]).should eq ["CREATE TYPE \"status\" AS ENUM ('draft', 'published')"]
      pg.create_enum_statements(:status, [:a], if_not_exists: true).first.should contain "EXCEPTION WHEN duplicate_object"
      pg.add_enum_value_statements(:status, :archived, after: :published, if_not_exists: true)
        .should eq ["ALTER TYPE \"status\" ADD VALUE IF NOT EXISTS 'archived' AFTER 'published'"]
      pg.rename_enum_value_statements(:status, :draft, :pending).should eq ["ALTER TYPE \"status\" RENAME VALUE 'draft' TO 'pending'"]
      pg.rename_enum_statements(:status, :state).should eq ["ALTER TYPE \"status\" RENAME TO \"state\""]
      pg.drop_enum_statements(:status, if_exists: true).should eq ["DROP TYPE IF EXISTS \"status\""]
    end

    it "enables and disables extensions" do
      pg.enable_extension_statements("pgcrypto").should eq ["CREATE EXTENSION IF NOT EXISTS \"pgcrypto\""]
      pg.disable_extension_statements("pgcrypto").should eq ["DROP EXTENSION IF EXISTS \"pgcrypto\" CASCADE"]
    end

    it "rejects enums off PostgreSQL and treats extensions as a no-op there" do
      {Grant::Schema::Dialect::Mysql, Grant::Schema::Dialect::Sqlite}.each do |dialect|
        rec = Grant::Schema::RecordingStatements.new(dialect)
        expect_raises(Grant::Schema::UnsupportedOperation) { rec.create_enum_statements(:status, %w[a]) }
        rec.enable_extension_statements("pgcrypto").should be_empty
        expect_raises(Grant::Schema::UnsupportedOperation) do
          rec.create_table_statements(:t, &.citext(:email))
        end
      end
    end

    it "emits the PostgreSQL column types" do
      pg.create_table_statements(:m02b_types, id: false) do |t|
        t.hstore :attrs
        t.citext :email
        t.inet :ip
        t.cidr :net
        t.macaddr :mac
        t.ltree :path
        t.money :price
        t.jsonb :doc
        t.enum :state, enum_type: :status
      end.first.should eq "CREATE TABLE \"m02b_types\" (\n  \"attrs\" hstore,\n  \"email\" citext,\n  \"ip\" inet,\n  \"net\" cidr,\n  \"mac\" macaddr,\n  \"path\" ltree,\n  \"price\" money,\n  \"doc\" JSONB,\n  \"state\" status\n)"
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    it "creates an enum, uses it in a table, extends it, and drops it (PostgreSQL)" do
      next unless CURRENT_ADAPTER == "pg"
      statements.drop_table(:m02b_en, if_exists: true)
      statements.drop_enum(:m02b_status, if_exists: true)
      statements.create_enum(:m02b_status, %w[draft published])
      statements.create_enum(:m02b_status, %w[draft published], if_not_exists: true)
      expect_raises(Exception) { statements.create_enum(:m02b_status, %w[draft]) }
      schema.enums["m02b_status"].should eq ["draft", "published"]
      statements.create_table(:m02b_en) { |t| t.enum :state, enum_type: :m02b_status, default: "draft", null: false }
      SchemaFixture.exec "INSERT INTO m02b_en (state) VALUES ('published')"
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_en (state) VALUES ('nonsense')" }
      statements.add_enum_value(:m02b_status, :archived, after: :published)
      statements.rename_enum_value(:m02b_status, :draft, :pending)
      schema.enums["m02b_status"].should eq ["pending", "published", "archived"]
      statements.drop_table(:m02b_en)
      statements.drop_enum(:m02b_status)
      schema.enums.has_key?("m02b_status").should be_false
    end

    it "enables and disables an extension (PostgreSQL)" do
      next unless CURRENT_ADAPTER == "pg"
      statements.disable_extension("btree_gist")
      schema.extension_enabled?("btree_gist").should be_false
      statements.enable_extension("btree_gist")
      statements.enable_extension("btree_gist")
      schema.extension_enabled?("btree_gist").should be_true
      statements.disable_extension("btree_gist")
    end

    it "creates columns of the built-in PostgreSQL types (PostgreSQL)" do
      next unless CURRENT_ADAPTER == "pg"
      statements.drop_table(:m02b_ty, if_exists: true)
      statements.create_table(:m02b_ty) do |t|
        t.inet :ip
        t.cidr :net
        t.macaddr :mac
        t.money :price
        t.jsonb :doc
      end
      SchemaFixture.exec "INSERT INTO m02b_ty (ip, net, mac, price, doc) VALUES ('10.0.0.1', '10.0.0.0/8', '08:00:2b:01:02:03', 12.5, '{}')"
      schema.columns(:m02b_ty).map(&.sql_type).should eq ["bigint", "inet", "cidr", "macaddr", "money", "jsonb"]
      statements.drop_table(:m02b_ty)
    end

    it "treats extensions as a no-op where they do not exist" do
      next if CURRENT_ADAPTER == "pg"
      statements.enable_extension("pgcrypto")
      schema.extensions.should be_empty
    end
  end
end
