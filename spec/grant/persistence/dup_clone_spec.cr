require "../../spec_helper"
require "../../support/write_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CopyArticle < Grant::Base
    connection {{ adapter_literal }}
    table copy_articles

    column id : Int64, primary: true
    column title : String?
    column body : String?
    column views : Int32?
    timestamps
  end
{% end %}

CopyArticle.migrator.drop_and_create

describe "dup and clone" do
  before_each { CopyArticle.clear }

  describe "#dup" do
    it "returns a new record with the attributes but no identity" do
      original = CopyArticle.create!(title: "Hello", body: "World", views: 3)
      copy = original.dup

      copy.new_record?.should be_true
      copy.persisted?.should be_false
      copy.destroyed?.should be_false
      copy.id.should be_nil
      copy.title.should eq("Hello")
      copy.body.should eq("World")
      copy.views.should eq(3)
    end

    it "clears the creation and update timestamps" do
      original = CopyArticle.create!(title: "Stamped")
      original.created_at.should_not be_nil
      copy = original.dup
      copy.created_at.should be_nil
      copy.updated_at.should be_nil
      copy.save!
      copy.created_at.should_not be_nil
    end

    it "inserts a separate row when saved and leaves the original untouched" do
      original = CopyArticle.create!(title: "Original")
      copy = original.dup
      copy.title = "Copy"
      copy.save!

      copy.id.should_not be_nil
      copy.id.should_not eq(original.id)
      CopyArticle.count.should eq(2)
      CopyArticle.find!(original.id).title.should eq("Original")
      CopyArticle.find!(copy.id).title.should eq("Copy")
    end

    it "is unequal to the original" do
      original = CopyArticle.create!(title: "Original")
      (original.dup == original).should be_false
    end

    it "does not carry dirty history or pending changes into the copy" do
      original = CopyArticle.create!(title: "Original")
      original.title = "Edited"
      copy = original.dup
      copy.changed?.should be_false
      original.changed?.should be_true
      copy.title = "Other"
      original.title.should eq("Edited")
    end

    it "does not share the errors collection" do
      original = CopyArticle.new
      original.errors.add(:base, "broken")
      copy = original.dup
      copy.errors.size.should eq(0)
      original.errors.size.should eq(1)
    end

    it "forgets a destroyed state" do
      original = CopyArticle.create!(title: "Doomed")
      original.destroy
      copy = original.dup
      copy.destroyed?.should be_false
      copy.new_record?.should be_true
      copy.save!
      CopyArticle.count.should eq(1)
    end

    it "keeps the read-only flag, as ActiveRecord does" do
      original = CopyArticle.create!(title: "Frozen")
      original.readonly!
      original.dup.readonly?.should be_true
    end
  end

  describe "#clone" do
    it "keeps the identity and persisted state" do
      original = CopyArticle.create!(title: "Same")
      copy = original.clone

      copy.same?(original).should be_false
      copy.persisted?.should be_true
      copy.new_record?.should be_false
      copy.id.should eq(original.id)
      (copy == original).should be_true
    end

    it "has its own dirty tracking" do
      original = CopyArticle.create!(title: "Same")
      copy = original.clone
      original.title = "Edited"

      original.changed?.should be_true
      copy.changed?.should be_false
      copy.title.should eq("Same")
    end

    it "carries pending changes as separate state" do
      original = CopyArticle.create!(title: "Same")
      original.title = "Edited"
      copy = original.clone
      copy.changed?.should be_true
      copy.save!
      original.changed?.should be_true
      CopyArticle.find!(original.id).title.should eq("Edited")
    end

    it "saves as an update, not an insert" do
      original = CopyArticle.create!(title: "Same")
      copy = original.clone
      copy.title = "Updated"
      statements = WriteSqlCapture.statements { copy.save! }
      statements.size.should eq(1)
      statements.first.should match(/UPDATE/i)
      CopyArticle.count.should eq(1)
    end
  end
end
