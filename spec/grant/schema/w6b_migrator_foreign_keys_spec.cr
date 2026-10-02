require "../../support/test_connection"

class W6bFkAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_fk_authors

  column id : Int64, primary: true
  column name : String?
end

class W6bFkPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_fk_posts

  column id : Int64, primary: true
  column title : String?
  belongs_to w6b_fk_author, optional: true, constraint: {on_delete: :cascade, on_update: :restrict}
end

class W6bFkPlainPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_fk_plain_posts

  column id : Int64, primary: true
  belongs_to w6b_fk_author, optional: true
end

class W6bFkNamedPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_fk_named_posts

  column id : Int64, primary: true
  belongs_to editor : W6bFkAuthor, optional: true, foreign_key: editor_ref : Int64?, constraint: {name: "fk_named_editor"}
end

class W6bFkDefaultPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_fk_default_posts

  column id : Int64, primary: true
  belongs_to w6b_fk_author, optional: true, constraint: true
end

describe "Migrator foreign keys from belongs_to on #{CURRENT_ADAPTER}" do
  quote = CURRENT_ADAPTER == "mysql" ? "`" : "\""

  before_each do
    TestConnection.ensure_registered
    W6bFkPost.migrator.drop
    W6bFkDefaultPost.migrator.drop
    W6bFkNamedPost.migrator.drop
    W6bFkPlainPost.migrator.drop
    W6bFkAuthor.migrator.drop_and_create
  end

  after_all do
    W6bFkPost.migrator.drop
    W6bFkDefaultPost.migrator.drop
    W6bFkNamedPost.migrator.drop
    W6bFkPlainPost.migrator.drop
    W6bFkAuthor.migrator.drop
  end

  it "emits FOREIGN KEY with the referential actions inside CREATE TABLE" do
    sql = W6bFkPost.migrator.create_sql
    sql.should contain "CONSTRAINT #{quote}fk_w6b_fk_posts_w6b_fk_author_id#{quote} FOREIGN KEY " \
                       "(#{quote}w6b_fk_author_id#{quote}) REFERENCES #{quote}w6b_fk_authors#{quote} (#{quote}id#{quote}) " \
                       "ON DELETE CASCADE ON UPDATE RESTRICT"
  end

  it "emits a bare FOREIGN KEY for constraint: true and honors name:" do
    W6bFkDefaultPost.migrator.create_sql.should contain "REFERENCES #{quote}w6b_fk_authors#{quote} (#{quote}id#{quote})\n"
    sql = W6bFkNamedPost.migrator.create_sql
    sql.should contain "CONSTRAINT #{quote}fk_named_editor#{quote} FOREIGN KEY (#{quote}editor_ref#{quote})"
  end

  it "emits nothing without constraint:" do
    W6bFkPlainPost.migrator.create_sql.should_not contain "FOREIGN KEY"
    W6bFkPlainPost.migrator.create_statements.size.should eq 1
  end

  it "creates the key, reads it back and enforces it" do
    W6bFkPost.migrator.create
    key = W6bFkPost.adapter.schema.foreign_keys(:w6b_fk_posts).first
    key.to_table.should eq "w6b_fk_authors"
    key.columns.should eq ["w6b_fk_author_id"]
    key.on_delete.should eq Grant::Schema::ReferentialAction::Cascade
    key.on_update.should eq Grant::Schema::ReferentialAction::Restrict

    author = W6bFkAuthor.create!(name: "ada")
    post = W6bFkPost.create!(title: "t", w6b_fk_author_id: author.id)
    W6bFkPost.find!(post.id).w6b_fk_author!.name.should eq "ada"

    expect_raises(Grant::ErrorBase) { W6bFkPost.create!(title: "orphan", w6b_fk_author_id: 999_999_i64) }
    W6bFkPost.where(title: "orphan").count.should eq 0

    author.destroy
    W6bFkPost.count.should eq 0
  end

  it "creates a named key on a custom foreign key column" do
    W6bFkNamedPost.migrator.create
    W6bFkNamedPost.adapter.schema.foreign_keys(:w6b_fk_named_posts).map(&.columns).should eq [["editor_ref"]]
    expect_raises(Grant::ErrorBase) { W6bFkNamedPost.create!(editor_ref: 424_242_i64) }
  end

  it "leaves the table without a key when constraint: is not declared" do
    W6bFkPlainPost.migrator.create
    W6bFkPlainPost.adapter.schema.foreign_keys(:w6b_fk_plain_posts).should be_empty
    W6bFkPlainPost.create!(w6b_fk_author_id: 777_i64).id.should_not be_nil
  end

  it "needs the parent table first" do
    W6bFkAuthor.migrator.drop
    if CURRENT_ADAPTER == "sqlite"
      # SQLite resolves the parent when a row is written, not when the table is created.
      W6bFkPost.migrator.create
      expect_raises(Grant::ErrorBase) { W6bFkPost.create!(title: "x", w6b_fk_author_id: 1_i64) }
    else
      expect_raises(Grant::ErrorBase) { W6bFkPost.migrator.create }
    end
  end

  if CURRENT_ADAPTER == "pg"
    it "declares a deferrable key on PostgreSQL" do
      sql = Grant::Schema::ForeignKeyDefinition.new("p", "a", ["a_id"], ["id"], deferrable: :deferred).constraint_sql(Grant::Schema::Dialect::Pg)
      sql.should end_with "DEFERRABLE INITIALLY DEFERRED"
    end
  end
end
