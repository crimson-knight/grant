require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class HbPost < Grant::Base
    connection {{ adapter_literal }}
    table hb_posts
    column id : Int64, primary: true
    column title : String?
    has_and_belongs_to_many :hb_tags
  end

  class HbTag < Grant::Base
    connection {{ adapter_literal }}
    table hb_tags
    column id : Int64, primary: true
    column label : String?
    has_and_belongs_to_many :hb_posts
  end

  class HbWriter < Grant::Base
    connection {{ adapter_literal }}
    table hb_writers
    column id : Int64, primary: true
    column name : String?
    has_and_belongs_to_many :hb_volumes, class_name: HbVolume, join_table: :hb_authorships,
      foreign_key: :writer_id, association_foreign_key: :volume_id, singular: :hb_volume
  end

  class HbVolume < Grant::Base
    connection {{ adapter_literal }}
    table hb_volumes
    column id : Int64, primary: true
    column name : String?
  end
{% end %}

# Join tables carry no primary key, as in ActiveRecord's create_join_table.
private def create_join_table(join_model, owner_column : String, target_column : String) : Nil
  table = join_model.quoted_table_name
  join_model.adapter.open do |db|
    db.exec "DROP TABLE IF EXISTS #{table}"
    db.exec "CREATE TABLE #{table} (#{join_model.quote(owner_column)} BIGINT NOT NULL, #{join_model.quote(target_column)} BIGINT NOT NULL)"
  end
end

describe "has_and_belongs_to_many" do
  before_all do
    HbPost.migrator.drop_and_create
    HbTag.migrator.drop_and_create
    create_join_table(HbPost::HABTM_HbTags, "hb_post_id", "hb_tag_id")
    HbWriter.migrator.drop_and_create
    HbVolume.migrator.drop_and_create
    create_join_table(HbWriter::HABTM_HbVolumes, "writer_id", "volume_id")
  end

  before_each do
    HbPost::HABTM_HbTags.clear
    HbWriter::HABTM_HbVolumes.clear
    HbPost.clear
    HbTag.clear
    HbWriter.clear
    HbVolume.clear
  end

  describe "the hidden join model" do
    it "is namespaced under the owner and maps the lexically ordered table" do
      HbPost::HABTM_HbTags.table_name.should eq("hb_posts_hb_tags")
      HbTag::HABTM_HbPosts.table_name.should eq("hb_posts_hb_tags")
    end

    it "honors join_table:, foreign_key: and association_foreign_key:" do
      HbWriter::HABTM_HbVolumes.table_name.should eq("hb_authorships")

      writer = HbWriter.create!(name: "w")
      volume = HbVolume.create!(name: "v")
      writer.hb_volumes << volume

      HbWriter::HABTM_HbVolumes.where(writer_id: writer.id, volume_id: volume.id).count.should eq(1)
      writer.hb_volume_ids.should eq([volume.id])
    end

    it "has no surrogate id column" do
      HbPost::HABTM_HbTags.fields.should eq(["hb_post_id", "hb_tag_id"])
    end
  end

  describe "writers" do
    it "<< inserts a row into the join table for a saved and an unsaved tag" do
      post = HbPost.create!(title: "p")
      saved = HbTag.create!(label: "saved")
      fresh = HbTag.new(label: "fresh")

      post.hb_tags << saved << fresh

      fresh.persisted?.should be_true
      HbPost::HABTM_HbTags.where(hb_post_id: post.id).count.should eq(2)
      HbPost.find!(post.id).hb_tags.compact_map(&.label).sort!.should eq(["fresh", "saved"])
    end

    it "appends many tags with one INSERT" do
      post = HbPost.create!(title: "p")
      tags = Array.new(3) { |i| HbTag.create!(label: "t#{i}") }

      statements = StatementRecorder.statements { post.hb_tags.concat(tags) }

      StatementRecorder.count(statements, "INSERT INTO", "hb_posts_hb_tags").should eq(1)
    end

    it "delete removes only the link, with a composite condition" do
      post = HbPost.create!(title: "p")
      other = HbPost.create!(title: "o")
      tag = HbTag.create!(label: "t")
      keep = HbTag.create!(label: "keep")
      post.hb_tags << tag << keep
      other.hb_tags << tag

      statements = StatementRecorder.statements { post.hb_tags.delete(tag) }

      StatementRecorder.count(statements, "DELETE FROM").should eq(1)
      post.hb_tags.map(&.id).should eq([keep.id])
      other.hb_tags.map(&.id).should eq([tag.id])
      HbTag.find(tag.id).should_not be_nil
    end

    it "destroy removes only the link and keeps a tag other posts share" do
      post = HbPost.create!(title: "p")
      other = HbPost.create!(title: "o")
      tag = HbTag.create!(label: "shared")
      post.hb_tags << tag
      other.hb_tags << tag

      post.hb_tags.destroy(tag)

      post.hb_tags.to_a.should be_empty
      other.hb_tags.map(&.id).should eq([tag.id])
      HbTag.find(tag.id).should_not be_nil
    end

    it "clear removes every link of the owner and keeps the tags" do
      post = HbPost.create!(title: "p")
      2.times { |i| post.hb_tags << HbTag.create!(label: "t#{i}") }

      post.hb_tags.clear

      HbPost::HABTM_HbTags.count.should eq(0)
      HbTag.count.should eq(2)
    end

    it "build and create link the tag" do
      post = HbPost.create!(title: "p")

      built = post.hb_tags.build(label: "b")
      created = post.hb_tags.create(label: "c")

      created.persisted?.should be_true
      HbPost::HABTM_HbTags.where(hb_post_id: post.id).count.should eq(1)
      post.save.should be_true
      built.persisted?.should be_true
      HbPost::HABTM_HbTags.where(hb_post_id: post.id).count.should eq(2)
    end

    it "hb_tag_ids= diffs the ids with one INSERT and one DELETE" do
      post = HbPost.create!(title: "p")
      a = HbTag.create!(label: "a")
      b = HbTag.create!(label: "b")
      c = HbTag.create!(label: "c")
      post.hb_tag_ids = [a.id, b.id]

      statements = StatementRecorder.statements { post.hb_tag_ids = [b.id, c.id] }

      StatementRecorder.count(statements, "INSERT INTO").should eq(1)
      StatementRecorder.count(statements, "DELETE FROM").should eq(1)
      post.hb_tag_ids.map(&.to_s).sort!.should eq([b.id, c.id].map(&.to_s).sort!)
    end

    it "raises RecordNotFound for a missing tag id" do
      post = HbPost.create!(title: "p")

      expect_raises(Grant::RecordNotFound) { post.hb_tag_ids = [999_999_i64] }
    end
  end

  describe "both sides" do
    it "sees a link from either model" do
      post = HbPost.create!(title: "p")
      tag = HbTag.create!(label: "t")

      post.hb_tags << tag

      HbTag.find!(tag.id).hb_posts.map(&.id).should eq([post.id])
      HbTag.find!(tag.id).hb_post_ids.should eq([post.id])
    end

    it "writes from the tag side into the same table" do
      post = HbPost.create!(title: "p")
      tag = HbTag.create!(label: "t")

      tag.hb_posts << post

      HbPost.find!(post.id).hb_tags.map(&.id).should eq([tag.id])
      HbPost::HABTM_HbTags.count.should eq(1)
    end

    it "deleting from one side is visible on the other" do
      post = HbPost.create!(title: "p")
      tag = HbTag.create!(label: "t")
      post.hb_tags << tag

      tag.hb_posts.delete(post)

      post.hb_tags.to_a.should be_empty
    end
  end

  describe "destroying the owner" do
    it "deletes its join rows and keeps the other side" do
      post = HbPost.create!(title: "p")
      tag = HbTag.create!(label: "t")
      post.hb_tags << tag

      post.destroy

      HbPost::HABTM_HbTags.count.should eq(0)
      HbTag.find(tag.id).should_not be_nil
    end
  end

  describe "callbacks" do
    it "is a has_many :through reflection" do
      reflection = HbPost.reflect_on_association(:hb_tags)
      reflection.should_not be_nil
      reflection.not_nil!.macro.should eq(:has_many)
    end
  end
end
