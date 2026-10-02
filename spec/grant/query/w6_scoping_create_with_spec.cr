require "../../spec_helper"

class W6scPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6sc_posts

  column id : Int64, primary: true
  column title : String?
  column published : Bool = false
  column status : String = "new"
  column score : Int32 = 0
  column owner_id : Int64?
end

class W6scNote < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6sc_notes

  column id : Int64, primary: true
  column published : Bool = false
end

class W6scItem < Grant::Base
  include Grant::STI
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6sc_items

  column id : Int64, primary: true
  column type : String
  column title : String?
  column approved : Bool = false
end

class W6scBook < W6scItem
end

class W6scMagazine < W6scItem
end

describe "Model.scoping and new records" do
  before_all do
    W6scPost.migrator.drop_and_create
    W6scNote.migrator.drop_and_create
    W6scItem.migrator.drop_and_create
  end

  before_each do
    W6scPost.clear
    W6scNote.clear
    W6scItem.clear
  end

  describe "Model.new" do
    it "starts from the scope's equality predicates" do
      W6scPost.where(published: true).scoping do
        W6scPost.new.published.should be_true
        W6scPost.new(title: "x").published.should be_true
        W6scPost.new({"title" => "y"}).published.should be_true
        W6scPost.new(&.title=("z")).published.should be_true
      end
    end

    it "lets explicit arguments win" do
      W6scPost.where(published: true, status: "live").scoping do
        post = W6scPost.new(published: false)
        post.published.should be_false
        post.status.should eq("live")
      end
    end

    it "applies several predicates, ranges and lists are ignored" do
      W6scPost.where(published: true, status: "live").where(:score, :gt, 3).where(owner_id: [1, 2]).scoping do
        post = W6scPost.new
        post.published.should be_true
        post.status.should eq("live")
        post.score.should eq(0)
        post.owner_id.should be_nil
      end
    end

    it "stops applying when the block ends, also when it raises" do
      W6scPost.where(published: true).scoping { W6scPost.new.published.should be_true }
      W6scPost.new.published.should be_false
      expect_raises(Exception, "boom") do
        W6scPost.where(published: true).scoping { raise "boom" }
      end
      W6scPost.new.published.should be_false
    end

    it "nests: the inner relation replaces the outer one" do
      W6scPost.where(status: "outer").scoping do
        W6scPost.scoping(W6scPost.unscoped.where(status: "inner")) do
          W6scPost.new.status.should eq("inner")
        end
        W6scPost.new.status.should eq("outer")
      end
    end

    it "does not reach another model" do
      W6scPost.where(published: true).scoping do
        W6scNote.new.published.should be_false
      end
    end

    it "is ignored by unscoped" do
      W6scPost.where(published: true).scoping do
        W6scPost.unscoped { |_| W6scPost.new.published }.should be_false
      end
    end

    it "does not leak into a fiber spawned inside the block" do
      seen = Channel(Bool).new
      W6scPost.where(published: true).scoping do
        spawn { seen.send(W6scPost.new.published) }
        seen.receive.should be_false
        W6scPost.new.published.should be_true
      end
    end
  end

  describe "create and create!" do
    it "persists the scope's attributes" do
      W6scPost.where(published: true).scoping do
        W6scPost.create(title: "a").published.should be_true
        W6scPost.create!(title: "b").published.should be_true
        W6scPost.create({"title" => "c"}).published.should be_true
      end
      W6scPost.where(published: true).count.should eq(3)
      W6scPost.where(published: false).count.should eq(0)
    end

    it "persists create_with defaults of the scoping relation" do
      W6scPost.create_with(status: "draft").scoping do
        post = W6scPost.create!(title: "d")
        post.status.should eq("draft")
        W6scPost.find!(post.id).status.should eq("draft")
      end
    end

    it "combines a where and create_with, explicit values still win" do
      W6scPost.where(published: true).create_with(status: "draft").scoping do
        post = W6scPost.create!(title: "e", status: "final")
        post.published.should be_true
        post.status.should eq("final")
      end
    end

    it "works through find_or_create_by and the relation methods" do
      W6scPost.where(published: true).scoping do
        W6scPost.find_or_create_by(title: "f").published.should be_true
        W6scPost.where(score: 9).create!(title: "g").published.should be_true
      end
    end
  end

  describe "loading records" do
    it "does not seed records hydrated from rows" do
      W6scPost.create!(title: "h", published: false, status: "kept")
      W6scPost.where(published: true).scoping do
        # The projection leaves `published` unselected: it keeps its column
        # default, not the scope's value.
        loaded = W6scPost.unscoped.select(:id, :title).first!
        loaded.title.should eq("h")
        loaded.published.should be_false
        W6scPost.unscoped.where(title: "h").first!.status.should eq("kept")
      end
    end

    it "does not change counts or finders" do
      W6scPost.create!(title: "i", published: true)
      W6scPost.create!(title: "j", published: false)
      W6scPost.where(published: true).scoping do
        W6scPost.count.should eq(1)
        W6scPost.all.map(&.title).should eq(["i"])
      end
    end
  end

  describe "single table inheritance" do
    it "applies a parent's scoping relation to its subclasses" do
      W6scBook.create!(title: "b1", approved: true)
      W6scBook.create!(title: "b2", approved: false)
      W6scMagazine.create!(title: "m1", approved: true)

      W6scItem.where(approved: true).scoping do
        W6scItem.count.should eq(2)
        W6scBook.count.should eq(1)
        W6scBook.all.map(&.title).should eq(["b1"])
        W6scMagazine.count.should eq(1)
        W6scBook.where(title: "b2").count.should eq(0)
      end
      W6scBook.count.should eq(2)
    end

    it "keeps the subclass's own type filter" do
      W6scBook.create!(title: "b1", approved: true)
      W6scMagazine.create!(title: "m1", approved: true)
      W6scItem.where(approved: true).scoping do
        W6scBook.all.map(&.title).should eq(["b1"])
        W6scMagazine.all.map(&.title).should eq(["m1"])
      end
    end

    it "gives new subclass records the parent's scope attributes" do
      W6scItem.where(approved: true).scoping do
        book = W6scBook.new(title: "n")
        book.approved.should be_true
        book.type.should eq("W6scBook")
        W6scBook.create!(title: "o").approved.should be_true
      end
      W6scBook.where(title: "o").first!.approved.should be_true
    end

    it "lets a subclass relation take precedence for that subclass" do
      W6scBook.create!(title: "b1", approved: true)
      W6scBook.create!(title: "b2", approved: false)
      W6scItem.where(approved: true).scoping do
        W6scBook.scoping(W6scBook.unscoped.where(approved: false)) do
          W6scBook.all.map(&.title).should eq(["b2"])
        end
      end
    end

    it "is hidden by unscoped on the subclass" do
      W6scBook.create!(title: "b1", approved: false)
      W6scItem.where(approved: true).scoping do
        W6scBook.unscoped { |_| W6scBook.count }.should eq(1)
        W6scBook.count.should eq(0)
      end
    end
  end
end
