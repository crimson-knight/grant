require "../../support/schema_fixture"

# What only a live server shows: catalog reads, fractional time defaults,
# column restatement and key actions. The examples that name MySQL run when
# CURRENT_ADAPTER=mysql; the ones without a condition hold on every adapter.
describe "live DDL and catalog round trip (#{CURRENT_ADAPTER})" do
  statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
  adapter = SchemaFixture.adapter

  before_each do
    statements.drop_table(:w6b_live_children, :w6b_live, if_exists: true)
    statements.create_table(:w6b_live, comment: "Live table") do |t|
      t.string :name, null: false, limit: 40, comment: "Display name"
      t.string :role, null: false, default: "it's member"
      t.integer :qty, default: 3
      t.boolean :active, null: false, default: true
      t.datetime :stamped, default_sql: "CURRENT_TIMESTAMP"
      t.decimal :price, precision: 10, scale: 2, default: 1.5
      t.timestamps precision: 3
      t.index :name, unique: true
    end
  end

  after_all { statements.drop_table(:w6b_live_children, :w6b_live, if_exists: true) }

  it "reads columns, defaults and nullability back from the catalog" do
    adapter.reset_schema_caches!
    columns = adapter.schema.columns(:w6b_live).index_by(&.name)
    columns.keys.should eq ["id", "name", "role", "qty", "active", "stamped", "price", "created_at", "updated_at"]
    columns["name"].null?.should be_false
    columns["name"].primary_key?.should be_false
    columns["id"].primary_key?.should be_true
    columns["qty"].default.to_s.should contain "3"
    columns["role"].default.to_s.should contain "it"
    columns["stamped"].default.to_s.upcase.should contain "CURRENT_TIMESTAMP"
    columns["created_at"].null?.should be_false
  end

  it "stores the defaults it was given" do
    insert = CURRENT_ADAPTER == "mysql" ? "INSERT INTO w6b_live (name, created_at, updated_at) VALUES ('a', NOW(), NOW())" : "INSERT INTO w6b_live (name, created_at, updated_at) VALUES ('a', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    adapter.open { |db| db.exec insert }
    adapter.open { |db| db.query_one("SELECT role FROM w6b_live", as: String) }.should eq "it's member"
    adapter.open { |db| db.query_one("SELECT qty FROM w6b_live", as: Int).to_i64 }.should eq 3
    adapter.open { |db| db.query_one("SELECT stamped FROM w6b_live", as: Time?) }.should_not be_nil
  end

  it "reads indexes, with their uniqueness, back from the catalog" do
    adapter.reset_schema_caches!
    index = adapter.schema.indexes(:w6b_live).find! { |info| info.columns == ["name"] }
    index.unique?.should be_true
  end

  it "reads foreign key actions back from the catalog" do
    statements.create_table(:w6b_live_children) do |t|
      t.references :live, foreign_key: {to_table: :w6b_live, on_delete: :cascade, on_update: :restrict}
    end
    adapter.reset_schema_caches!
    key = adapter.schema.foreign_keys(:w6b_live_children).first
    key.to_table.should eq "w6b_live"
    key.on_delete.should eq Grant::Schema::ReferentialAction::Cascade
    key.on_update.should eq Grant::Schema::ReferentialAction::Restrict
  end

  it "keeps the default and comment when only the type changes" do
    statements.change_column(:w6b_live, :qty, :bigint)
    adapter.reset_schema_caches!
    info = adapter.schema.columns(:w6b_live).find! { |column| column.name == "qty" }
    info.sql_type.downcase.should contain "bigint"
    info.default.to_s.should contain "3"
    statements.change_column(:w6b_live, :stamped, :datetime, precision: 6)
    adapter.schema.columns(:w6b_live).find! { |column| column.name == "stamped" }.default.to_s.upcase.should contain "CURRENT_TIMESTAMP"
  end

  it "drops a default on a nullable column so an insert that skips it stores NULL" do
    statements.change_column_default(:w6b_live, :qty, to: nil)
    adapter.reset_schema_caches!
    adapter.schema.columns(:w6b_live).find! { |column| column.name == "qty" }.default.should be_nil
    adapter.open { |db| db.exec "INSERT INTO w6b_live (name, created_at, updated_at) VALUES ('b', '2024-01-01 00:00:00', '2024-01-01 00:00:00')" }
    adapter.open { |db| db.query_one("SELECT qty FROM w6b_live WHERE name = 'b'", as: Int32?) }.should be_nil
  end

  it "restates a column with a quoted default through change_column_null" do
    statements.change_column_null(:w6b_live, :role, true)
    statements.change_column_null(:w6b_live, :role, false)
    adapter.reset_schema_caches!
    adapter.schema.columns(:w6b_live).find! { |column| column.name == "role" }.default.to_s.should contain "it"
    adapter.open { |db| db.exec "INSERT INTO w6b_live (name, created_at, updated_at) VALUES ('c', '2024-01-01 00:00:00', '2024-01-01 00:00:00')" }
    adapter.open { |db| db.query_one("SELECT role FROM w6b_live WHERE name = 'c'", as: String) }.should eq "it's member"
  end

  if CURRENT_ADAPTER == "mysql"
    it "uses fractional digits on a CURRENT_TIMESTAMP default of a DATETIME(6) column" do
      statements.create_table(:w6b_live_children, force: true) do |t|
        t.datetime :at, default_sql: "CURRENT_TIMESTAMP"
        t.datetime :coarse, precision: 0, default_sql: "CURRENT_TIMESTAMP"
      end
      adapter.reset_schema_caches!
      columns = adapter.schema.columns(:w6b_live_children).index_by(&.name)
      columns["at"].default.to_s.upcase.should eq "CURRENT_TIMESTAMP(6)"
      columns["coarse"].default.to_s.upcase.should eq "CURRENT_TIMESTAMP"
    end

    it "reports string defaults as quoted SQL text and numbers as bare text" do
      adapter.reset_schema_caches!
      columns = adapter.schema.columns(:w6b_live).index_by(&.name)
      columns["role"].default.should eq "'it''s member'"
      columns["qty"].default.should eq "3"
      columns["active"].default.should eq "1"
    end

    it "reads the expression of a functional index" do
      adapter.open { |db| db.exec "CREATE INDEX w6b_live_lower_name ON w6b_live ((lower(name)))" }
      adapter.reset_schema_caches!
      info = adapter.schema.indexes(:w6b_live).find! { |index| index.name == "w6b_live_lower_name" }
      info.columns.first.should contain "lower"
    end

    it "reads the table comment and column comment" do
      adapter.reset_schema_caches!
      adapter.schema.columns(:w6b_live).find! { |column| column.name == "name" }.comment.should eq "Display name"
      adapter.open { |db| db.scalar("SELECT TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'w6b_live'").as(String) }.should eq "Live table"
    end
  end
end
