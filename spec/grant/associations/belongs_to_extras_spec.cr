require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class BteAuthor < Grant::Base
    connection {{ adapter_literal }}
    table bte_authors
    column id : Int64, primary: true
    column name : String?
  end

  class BtePost < Grant::Base
    connection {{ adapter_literal }}
    table bte_posts
    column id : Int64, primary: true
    column title : String?
    belongs_to :bte_author, class_name: BteAuthor, foreign_key: bte_author_id : Int64?,
      default: ->(post : BtePost) { BteAuthor.find_by(name: "house") }
  end

  class BteNote < Grant::Base
    connection {{ adapter_literal }}
    table bte_notes
    column id : Int64, primary: true
    belongs_to :bte_author, class_name: BteAuthor, foreign_key: bte_author_id : Int64?, optional: true
  end
{% end %}

describe "belongs_to extras" do
  before_all do
    BteAuthor.migrator.drop_and_create
    BtePost.migrator.drop_and_create
    BteNote.migrator.drop_and_create
  end

  before_each do
    BtePost.clear
    BteNote.clear
    BteAuthor.clear
  end

  describe "default:" do
    it "fills a missing parent before validation on create" do
      house = BteAuthor.create!(name: "house")

      post = BtePost.new(title: "t")
      post.save.should be_true

      post.bte_author_id.should eq(house.id)
      BtePost.find!(post.id).bte_author_id.should eq(house.id)
    end

    it "satisfies the required-parent validation" do
      BteAuthor.create!(name: "house")

      BtePost.new(title: "t").valid?.should be_true
    end

    it "does not override a parent that is set" do
      BteAuthor.create!(name: "house")
      other = BteAuthor.create!(name: "other")

      post = BtePost.new(title: "t")
      post.bte_author = other
      post.save.should be_true

      post.bte_author_id.should eq(other.id)
    end

    it "leaves the key empty when the default finds nothing" do
      post = BtePost.new(title: "t")

      post.valid?.should be_false
      post.bte_author_id.should be_nil
    end

    it "does not run on update" do
      house = BteAuthor.create!(name: "house")
      post = BtePost.create!(title: "t")
      post.bte_author_id.should eq(house.id)

      BtePost.where(id: post.id).update_all({"bte_author_id" => nil.as(Grant::Columns::Type)})
      reloaded = BtePost.find!(post.id)
      reloaded.title = "changed"
      reloaded.save(validate: false).should be_true

      BtePost.find!(post.id).bte_author_id.should be_nil
    end
  end

  describe "association_changed? and association_previously_changed?" do
    it "reflect the foreign key's dirty state" do
      one = BteAuthor.create!(name: "one")
      two = BteAuthor.create!(name: "two")
      note = BteNote.create!(bte_author_id: one.id)

      note.bte_author_changed?.should be_false
      note.bte_author_previously_changed?.should be_true # the create set the key

      note = BteNote.find!(note.id)
      note.bte_author_changed?.should be_false
      note.bte_author_previously_changed?.should be_false

      note.bte_author = two
      note.bte_author_changed?.should be_true
      note.bte_author_previously_changed?.should be_false

      note.save!
      note.bte_author_changed?.should be_false
      note.bte_author_previously_changed?.should be_true

      note.save!
      note.bte_author_previously_changed?.should be_false
    end

    it "is true while an unsaved parent is assigned" do
      note = BteNote.new
      note.bte_author_changed?.should be_false

      note.bte_author = BteAuthor.new(name: "fresh")
      note.bte_author_changed?.should be_true
    end
  end

  describe "assigning an unsaved parent" do
    it "saves the parent with the child" do
      note = BteNote.new
      note.bte_author = BteAuthor.new(name: "fresh")

      note.save.should be_true

      BteAuthor.find_by(name: "fresh").not_nil!.id.should eq(note.bte_author_id)
    end
  end
end
