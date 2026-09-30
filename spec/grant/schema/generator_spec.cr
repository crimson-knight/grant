require "../../spec_helper"

describe Grant::Schema::Generator do
  describe ".parse" do
    it "parses AddEmailToUsers into add_column plus index" do
      plan = Grant::Schema::Generator.parse("AddEmailToUsers", ["email:string:index"])
      plan.kind.should eq Grant::Schema::Generator::Kind::AddColumns
      plan.table.should eq "users"
      plan.class_name.should eq "AddEmailToUsers"
      plan.steps.map(&.method).should eq ["add_column", "add_index"]
      plan.steps[0].arguments.should eq [":users", ":email", ":string"]
      plan.steps[1].arguments.should eq [":users", ":email"]
    end

    it "makes a unique index for the uniq modifier" do
      plan = Grant::Schema::Generator.parse("AddSlugToPosts", ["slug:string:uniq"])
      plan.steps[1].arguments.should eq [":posts", ":slug", "unique: true"]
    end

    it "adds several columns, with limit and precision options" do
      plan = Grant::Schema::Generator.parse("AddDetailsToProducts", ["part_number:string{20}", "price:decimal{10,2}", "stock:integer"])
      plan.steps.map(&.arguments).should eq [
        [":products", ":part_number", ":string", "limit: 20"],
        [":products", ":price", ":decimal", "precision: 10", "scale: 2"],
        [":products", ":stock", ":integer"],
      ]
    end

    it "parses CreateUsers into create_table with the attributes and timestamps" do
      plan = Grant::Schema::Generator.parse("CreateUsers", ["email:string:uniq", "age:integer", "team:references"])
      plan.kind.should eq Grant::Schema::Generator::Kind::CreateTable
      plan.table.should eq "users"
      step = plan.steps.first
      step.method.should eq "create_table"
      step.arguments.should eq [":users"]
      step.block_lines.should eq [
        "t.string :email",
        "t.integer :age",
        "t.references :team, foreign_key: true",
        "t.index :email, unique: true",
        "t.timestamps",
      ]
    end

    it "parses RemoveEmailFromUsers with the type, so it can be reversed" do
      plan = Grant::Schema::Generator.parse("RemoveEmailFromUsers", ["email:string"])
      plan.kind.should eq Grant::Schema::Generator::Kind::RemoveColumns
      plan.steps.first.method.should eq "remove_column"
      plan.steps.first.arguments.should eq [":users", ":email", ":string"]
    end

    it "parses CreateJoinTableUsersGroups" do
      plan = Grant::Schema::Generator.parse("CreateJoinTableUsersGroups")
      plan.kind.should eq Grant::Schema::Generator::Kind::CreateJoinTable
      plan.steps.first.method.should eq "create_join_table"
      plan.steps.first.arguments.should eq [":users", ":groups"]
    end

    it "gives references on add a reference step and polymorphic ones no foreign key" do
      plan = Grant::Schema::Generator.parse("AddAuthorToPosts", ["author:references", "owner:belongs_to{polymorphic}"])
      plan.steps.map(&.method).should eq ["add_reference", "add_reference"]
      plan.steps[0].arguments.should eq [":posts", ":author", "foreign_key: true"]
      plan.steps[1].arguments.should eq [":posts", ":owner", "polymorphic: true"]
    end

    it "accepts snake_case names and an empty change for other names" do
      Grant::Schema::Generator.parse("add_email_to_users", ["email"]).class_name.should eq "AddEmailToUsers"
      plan = Grant::Schema::Generator.parse("BackfillUsers")
      plan.kind.should eq Grant::Schema::Generator::Kind::Blank
      plan.steps.should be_empty
    end

    it "rejects bad names and attributes" do
      expect_raises(Grant::Schema::GeneratorError, /name/) { Grant::Schema::Generator.parse("") }
      expect_raises(Grant::Schema::GeneratorError, /unknown type/) { Grant::Schema::Generator.parse("AddXToY", ["x:blob3"]) }
      expect_raises(Grant::Schema::GeneratorError, /unknown modifier/) { Grant::Schema::Generator.parse("AddXToY", ["x:string:fast"]) }
      expect_raises(Grant::Schema::GeneratorError, /twice/) { Grant::Schema::Generator.parse("AddXToY", ["x:string", "x:text"]) }
      expect_raises(Grant::Schema::GeneratorError, /two tables/) { Grant::Schema::Generator.parse("CreateJoinTableUsers") }
    end
  end

  describe ".render and .file_name" do
    it "renders the migration class for the timestamped version" do
      Grant::Schema::Generator.render("AddEmailToUsers", ["email:string:index"], 20260930120000_i64).should eq <<-CR
        class AddEmailToUsers < Grant::Schema::Migration
          migration_version 20260930120000

          def change
            add_column :users, :email, :string
            add_index :users, :email
          end
        end

        CR
    end

    it "formats a Time as a UTC timestamp version and file name" do
      time = Time.utc(2026, 9, 30, 12, 34, 56)
      Grant::Schema::Generator.version_number(time).should eq 20260930123456_i64
      Grant::Schema::Generator.file_name("AddEmailToUsers", time).should eq "20260930123456_add_email_to_users.cr"
    end
  end
end

# The class the generator renders for `AddEmailToM04Users email:string:index`,
# compiled here to show that the generated source is valid DSL and does what
# it says on a real database.
class M04AddEmailToUsers < Grant::Schema::Migration
  migration_version 20260930120001

  def change
    add_column :m04_gen_users, :email, :string
    add_index :m04_gen_users, :email
  end
end

describe "a generated migration" do
  it "renders source identical to the compiled class and runs on the database" do
    rendered = Grant::Schema::Generator.render("AddEmailToUsers", ["email:string:index"], 20260930120001_i64)
    rendered.should contain("add_column :users, :email, :string")

    adapter = Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER)
    adapter.open { |db| db.exec "DROP TABLE IF EXISTS m04_gen_users" }
    adapter.open { |db| db.exec "DROP TABLE IF EXISTS schema_migrations" }
    statements = Grant::Schema::AdapterStatements.new(adapter)
    statements.create_table(:m04_gen_users) { |t| t.string :name }
    begin
      context = Grant::Schema::MigrationContext.for(adapter, M04AddEmailToUsers, verbose: false)
      context.migrate.should eq [20260930120001_i64]
      adapter.reset_schema_caches!
      adapter.schema.column_exists?(:m04_gen_users, :email).should be_true
      adapter.schema.index_exists?(:m04_gen_users, [:email] of (String | Symbol)).should be_true
      context.rollback
      adapter.reset_schema_caches!
      adapter.schema.column_exists?(:m04_gen_users, :email).should be_false
    ensure
      adapter.open { |db| db.exec "DROP TABLE IF EXISTS m04_gen_users" }
      adapter.open { |db| db.exec "DROP TABLE IF EXISTS schema_migrations" }
      adapter.reset_schema_caches!
    end
  end
end
