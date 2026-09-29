require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class TwPost < Grant::Base
    connection {{ adapter_literal }}
    table tw_posts
    column id : Int64, primary: true
    column title : String?
    has_many :tw_taggings, class_name: TwTagging, foreign_key: :tw_post_id
    has_many :tw_tags, class_name: TwTag, through: :tw_taggings
  end

  class TwTag < Grant::Base
    connection {{ adapter_literal }}
    table tw_tags
    column id : Int64, primary: true
    column label : String?
    validate "label must be present" do |tag|
      !tag.label.to_s.empty?
    end
    has_many :tw_taggings, class_name: TwTagging, foreign_key: :tw_tag_id
    has_many :tw_posts, class_name: TwPost, through: :tw_taggings
  end

  class TwTagging < Grant::Base
    connection {{ adapter_literal }}
    table tw_taggings
    column id : Int64, primary: true
    column tw_post_id : Int64?
    column tw_tag_id : Int64?
    belongs_to :tw_post, class_name: TwPost, foreign_key: :tw_post_id, optional: true
    belongs_to :tw_tag, class_name: TwTag, foreign_key: :tw_tag_id, optional: true
  end
{% end %}

private def sorted_ids(ids) : Array(String)
  ids.map(&.to_s).sort!
end

describe "has_many :through writers" do
  before_all do
    TwPost.migrator.drop_and_create
    TwTag.migrator.drop_and_create
    TwTagging.migrator.drop_and_create
  end

  before_each do
    TwTagging.clear
    TwTag.clear
    TwPost.clear
  end

  describe "<< and append" do
    it "inserts a join row for a saved target" do
      post = TwPost.create!(title: "p")
      tag = TwTag.create!(label: "a")

      post.tw_tags << tag

      TwTagging.where(tw_post_id: post.id, tw_tag_id: tag.id).count.should eq(1)
      TwPost.find!(post.id).tw_tags.map(&.id).should eq([tag.id])
      TwTag.count.should eq(1)
    end

    it "saves an unsaved target and links it" do
      post = TwPost.create!(title: "p")
      tag = TwTag.new(label: "fresh")

      post.tw_tags << tag

      tag.persisted?.should be_true
      TwTagging.where(tw_post_id: post.id, tw_tag_id: tag.id).count.should eq(1)
    end

    it "inserts many join rows with one INSERT statement" do
      post = TwPost.create!(title: "p")
      tags = 3.times.map { |i| TwTag.create!(label: "t#{i}") }.to_a

      statements = StatementRecorder.statements { post.tw_tags.append(tags[0], tags[1], tags[2]) }

      StatementRecorder.count(statements, "INSERT INTO", "tw_taggings").should eq(1)
      TwTagging.where(tw_post_id: post.id).count.should eq(3)
    end

    it "does not insert a second row for a record already loaded" do
      post = TwPost.create!(title: "p")
      tag = TwTag.create!(label: "a")
      collection = post.tw_tags
      collection.load_target
      collection << tag
      collection << tag

      TwTagging.where(tw_post_id: post.id).count.should eq(1)
    end

    it "rolls back every join row and target when one target is invalid" do
      post = TwPost.create!(title: "p")
      good = TwTag.new(label: "good")
      bad = TwTag.new(label: "")

      expect_raises(Grant::RecordNotSaved) { post.tw_tags.append(good, bad) }

      TwTagging.count.should eq(0)
      TwTag.count.should eq(0)
    end

    it "waits for the owner to be saved when the owner is new" do
      post = TwPost.new(title: "later")
      tag = TwTag.create!(label: "a")
      post.tw_tags << tag
      TwTagging.count.should eq(0)

      post.save.should be_true

      TwTagging.where(tw_post_id: post.id, tw_tag_id: tag.id).count.should eq(1)
    end
  end

  describe "delete, clear and destroy" do
    it "deletes only the join rows and keeps the target" do
      post = TwPost.create!(title: "p")
      keep = TwTag.create!(label: "keep")
      drop = TwTag.create!(label: "drop")
      post.tw_tags << keep << drop

      removed = post.tw_tags.delete(drop)

      removed.map(&.id).should eq([drop.id])
      TwTagging.where(tw_post_id: post.id).count.should eq(1)
      TwTag.find(drop.id).should_not be_nil
      post.tw_tags.map(&.id).should eq([keep.id])
    end

    it "leaves other owners' links to the same target alone" do
      first = TwPost.create!(title: "1")
      second = TwPost.create!(title: "2")
      tag = TwTag.create!(label: "shared")
      first.tw_tags << tag
      second.tw_tags << tag

      first.tw_tags.delete(tag)

      second.tw_tags.map(&.id).should eq([tag.id])
    end

    it "clear removes all join rows in one statement and keeps targets" do
      post = TwPost.create!(title: "p")
      2.times { |i| post.tw_tags << TwTag.create!(label: "t#{i}") }

      statements = StatementRecorder.statements { post.tw_tags.clear }

      StatementRecorder.count(statements, "DELETE FROM").should eq(1)
      TwTagging.count.should eq(0)
      TwTag.count.should eq(2)
    end

    it "destroy removes the join rows and destroys the target" do
      post = TwPost.create!(title: "p")
      tag = TwTag.create!(label: "gone")
      post.tw_tags << tag

      post.tw_tags.destroy(tag)

      TwTagging.count.should eq(0)
      TwTag.find(tag.id).should be_nil
    end
  end

  describe "build and create" do
    it "build leaves the target unsaved and links it when the owner is saved" do
      post = TwPost.create!(title: "p")
      tag = post.tw_tags.build(label: "built")

      tag.persisted?.should be_false
      TwTagging.count.should eq(0)

      post.save.should be_true

      tag.persisted?.should be_true
      TwTagging.where(tw_post_id: post.id, tw_tag_id: tag.id).count.should eq(1)
    end

    it "create saves the target and inserts the join row" do
      post = TwPost.create!(title: "p")

      tag = post.tw_tags.create(label: "made")

      tag.persisted?.should be_true
      TwTagging.where(tw_post_id: post.id, tw_tag_id: tag.id).count.should eq(1)
    end

    it "create! raises for an invalid target and inserts no join row" do
      post = TwPost.create!(title: "p")

      expect_raises(Grant::RecordNotSaved) { post.tw_tags.create!(label: "") }

      TwTagging.count.should eq(0)
    end

    it "create with an array uses one transaction and one join INSERT per record set" do
      post = TwPost.create!(title: "p")

      tags = post.tw_tags.create([{label: "a"}, {label: "b"}])

      tags.map(&.persisted?).should eq([true, true])
      TwTagging.where(tw_post_id: post.id).count.should eq(2)
    end
  end

  describe "tag_ids=" do
    it "generates the reader and writer for a through collection" do
      post = TwPost.create!(title: "p")
      a = TwTag.create!(label: "a")
      b = TwTag.create!(label: "b")
      c = TwTag.create!(label: "c")

      post.tw_tag_ids = [a.id, b.id]
      sorted_ids(post.tw_tag_ids).should eq(sorted_ids([a.id, b.id]))

      post.tw_tag_ids = [b.id, c.id]
      sorted_ids(TwPost.find!(post.id).tw_tag_ids).should eq(sorted_ids([b.id, c.id]))
      TwTag.count.should eq(3)
      TwTagging.where(tw_post_id: post.id).count.should eq(2)
    end

    it "applies the difference with one INSERT and one DELETE" do
      post = TwPost.create!(title: "p")
      a = TwTag.create!(label: "a")
      b = TwTag.create!(label: "b")
      c = TwTag.create!(label: "c")
      post.tw_tag_ids = [a.id, b.id]

      statements = StatementRecorder.statements { post.tw_tag_ids = [b.id, c.id] }

      StatementRecorder.count(statements, "DELETE FROM").should eq(1)
      StatementRecorder.count(statements, "INSERT INTO").should eq(1)
    end

    it "raises RecordNotFound for a missing id and changes nothing" do
      post = TwPost.create!(title: "p")
      a = TwTag.create!(label: "a")
      post.tw_tag_ids = [a.id]

      expect_raises(Grant::RecordNotFound) { post.tw_tag_ids = [a.id, 999_999_i64] }

      post.tw_tag_ids.should eq([a.id])
    end
  end
end
