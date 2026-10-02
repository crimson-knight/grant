require "../../support/schema_fixture"

describe Grant::Schema::Introspection do
  schema = SchemaFixture.adapter.schema

  before_all { SchemaFixture.create! }
  after_all { SchemaFixture.drop! }

  describe "#tables" do
    it "lists the tables of the connection" do
      schema.tables.should contain("m01_authors")
      schema.tables.should contain("m01_posts")
      schema.tables.should_not contain("sqlite_sequence")
    end
  end

  describe "#table_exists?" do
    it "answers for strings and symbols" do
      schema.table_exists?(:m01_authors).should be_true
      schema.table_exists?("m01_authors").should be_true
      schema.table_exists?(:m01_nothing).should be_false
    end
  end

  describe "#columns" do
    it "describes every column in table order" do
      columns = schema.columns(:m01_authors)
      columns.map(&.name).should eq ["id", "email", "bio", "active", "created_at"]
      columns.map(&.position).should eq [1, 2, 3, 4, 5]
    end

    it "reports nullability, defaults and type families" do
      by_name = schema.columns(:m01_authors).index_by(&.name)
      by_name["email"].null?.should be_false
      by_name["email"].type_family.should eq Grant::Schema::TypeFamily::String
      by_name["email"].limit.should eq 120
      by_name["bio"].null?.should be_true
      by_name["bio"].type_family.should eq Grant::Schema::TypeFamily::Text
      by_name["bio"].default.should be_nil
      by_name["active"].default.should_not be_nil
      by_name["active"].type_family.should eq Grant::Schema::TypeFamily::Boolean
      by_name["created_at"].type_family.should eq Grant::Schema::TypeFamily::DateTime
    end

    it "reports precision and scale of decimals" do
      score = schema.columns(:m01_posts).find! { |column| column.name == "score" }
      score.type_family.should eq Grant::Schema::TypeFamily::Decimal
      score.precision.should eq 10
      score.scale.should eq 2
    end

    it "marks the auto-incrementing primary key" do
      id = schema.columns(:m01_authors).first
      id.primary_key?.should be_true
      id.auto_increment?.should be_true
      id.null?.should be_false
      id.type_family.should eq Grant::Schema::TypeFamily::Integer
    end

    it "raises TableNotFound for an unknown table" do
      expect_raises(Grant::Schema::TableNotFound, /m01_nothing/) { schema.columns(:m01_nothing) }
    end
  end

  describe "#column_exists?" do
    it "checks the name and optionally the type family" do
      schema.column_exists?(:m01_authors, :email).should be_true
      schema.column_exists?(:m01_authors, :email, Grant::Schema::TypeFamily::String).should be_true
      schema.column_exists?(:m01_authors, :email, Grant::Schema::TypeFamily::Integer).should be_false
      schema.column_exists?(:m01_authors, :nope).should be_false
      schema.column_exists?(:m01_nothing, :id).should be_false
    end
  end

  describe "#primary_key" do
    it "returns a single column key" do
      schema.primary_key(:m01_authors).should eq ["id"]
    end

    it "returns a composite key in key order" do
      schema.primary_key(:m01_memberships).should eq ["author_id", "group_id"]
    end
  end

  describe "#indexes" do
    it "lists indexes without the primary key" do
      indexes = schema.indexes(:m01_posts).index_by(&.name)
      indexes.keys.should contain("index_m01_posts_on_author_id_and_title")
      indexes.keys.should contain("index_m01_posts_on_score")
      composite = indexes["index_m01_posts_on_author_id_and_title"]
      composite.columns.should eq ["author_id", "title"]
      composite.unique?.should be_true
      indexes["index_m01_posts_on_score"].unique?.should be_false
      schema.indexes(:m01_authors).none?(&.unique?).should be_true
    end

    it "reports expression indexes" do
      pending!("MySQL expression index syntax is not created by the fixture") if CURRENT_ADAPTER == "mysql"
      index = schema.indexes(:m01_authors).find! { |candidate| candidate.name == "index_m01_authors_on_lower_email" }
      index.expression?.should be_true
      index.columns.first.should contain("lower")
    end

    it "answers index_exists?" do
      schema.index_exists?(:m01_posts, ["author_id", "title"], unique: true).should be_true
      schema.index_exists?(:m01_posts, ["title"]).should be_false
      schema.index_exists?(:m01_posts, name: "index_m01_posts_on_score").should be_true
    end
  end

  describe "#foreign_keys" do
    it "describes columns, target and actions" do
      key = schema.foreign_keys(:m01_posts).first
      key.columns.should eq ["author_id"]
      key.column.should eq "author_id"
      key.to_table.should eq "m01_authors"
      key.primary_key_columns.should eq ["id"]
      key.on_delete.should eq Grant::Schema::ReferentialAction::Cascade
      key.on_update.should eq Grant::Schema::ReferentialAction::NoAction
      key.name.should eq "fk_m01_posts_author" unless CURRENT_ADAPTER == "sqlite"
    end

    it "reads update and delete actions separately" do
      key = schema.foreign_keys(:m01_memberships).first
      key.on_update.should eq Grant::Schema::ReferentialAction::Cascade
      key.on_delete.should eq(CURRENT_ADAPTER == "mysql" ? Grant::Schema::ReferentialAction::Restrict : Grant::Schema::ReferentialAction::SetNull)
    end

    it "is empty for a table without keys and answers foreign_key_exists?" do
      schema.foreign_keys(:m01_authors).should be_empty
      schema.foreign_key_exists?(:m01_posts, to_table: :m01_authors).should be_true
      schema.foreign_key_exists?(:m01_posts, column: :author_id).should be_true
      schema.foreign_key_exists?(:m01_posts, column: :title).should be_false
    end
  end

  describe "TypeFamily.classify" do
    it "maps adapter type spellings to families" do
      {
        "bigint"                   => Grant::Schema::TypeFamily::Integer,
        "int(11)"                  => Grant::Schema::TypeFamily::Integer,
        "INTEGER"                  => Grant::Schema::TypeFamily::Integer,
        "smallserial"              => Grant::Schema::TypeFamily::Integer,
        "tinyint(1)"               => Grant::Schema::TypeFamily::Boolean,
        "character varying"        => Grant::Schema::TypeFamily::String,
        "double precision"         => Grant::Schema::TypeFamily::Float,
        "numeric(10,2)"            => Grant::Schema::TypeFamily::Decimal,
        "timestamp with time zone" => Grant::Schema::TypeFamily::DateTime,
        "date"                     => Grant::Schema::TypeFamily::Date,
        "bytea"                    => Grant::Schema::TypeFamily::Binary,
        "jsonb"                    => Grant::Schema::TypeFamily::Json,
        "uuid"                     => Grant::Schema::TypeFamily::Uuid,
        "point"                    => Grant::Schema::TypeFamily::Other,
        ""                         => Grant::Schema::TypeFamily::Other,
      }.each do |sql_type, family|
        Grant::Schema::TypeFamily.classify(sql_type).should eq family
      end
    end
  end
end
