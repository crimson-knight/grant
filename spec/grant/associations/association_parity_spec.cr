require "../../spec_helper"

# Standalone models for the association-parity features. Kept self-contained
# (own tables + nullable FKs) so this spec does not depend on shared models that
# carry required belongs_to validations.

class ParityAuthor < Grant::Base
  connection sqlite
  table parity_authors

  column id : Int64, primary: true
  column name : String?

  has_many :parity_posts, class_name: ParityPost, foreign_key: :parity_author_id
  # Lambda-form association scope: only published posts.
  has_many :published_parity_posts, -> { where(published: true) },
    class_name: ParityPost, foreign_key: :parity_author_id

  # dependent: :restrict_with_exception
  has_many :guarded_posts, class_name: ParityPost, foreign_key: :parity_author_id,
    dependent: :restrict_with_exception
end

class ParityPost < Grant::Base
  connection sqlite
  table parity_posts

  column id : Int64, primary: true
  column title : String?
  column published : Bool?

  belongs_to parity_author : ParityAuthor, foreign_key: parity_author_id : Int64?, optional: true
end

# Models for has_one :through with an explicit source:
class ParitySupplier < Grant::Base
  connection sqlite
  table parity_suppliers

  column id : Int64, primary: true
  column name : String?

  has_one :parity_account, class_name: ParityAccount, foreign_key: :parity_supplier_id
  # source: names the association on the join model (ParityAccount) whose target
  # (ParityAccountHistory) we resolve through. The join FK is `parity_history_id`.
  has_one :latest_history, class_name: ParityAccountHistory,
    through: :parity_accounts, source: :parity_history, foreign_key: :parity_supplier_id
end

class ParityAccount < Grant::Base
  connection sqlite
  table parity_accounts

  column id : Int64, primary: true
  column parity_supplier_id : Int64?
  column parity_history_id : Int64?
end

class ParityAccountHistory < Grant::Base
  connection sqlite
  table parity_account_histories

  column id : Int64, primary: true
  column note : String?
end

describe "association parity" do
  before_all do
    ParityPost.migrator.drop_and_create
    ParityAuthor.migrator.drop_and_create
    ParityAccountHistory.migrator.drop_and_create
    ParityAccount.migrator.drop_and_create
    ParitySupplier.migrator.drop_and_create
  end

  before_each do
    ParityPost.clear
    ParityAuthor.clear
    ParityAccount.clear
    ParityAccountHistory.clear
    ParitySupplier.clear
  end

  describe "collection <singular>_ids reader/writer" do
    it "reads the primary keys of the associated records" do
      author = ParityAuthor.new(name: "Ann")
      author.save

      p1 = ParityPost.new(title: "A", parity_author_id: author.id)
      p1.save
      p2 = ParityPost.new(title: "B", parity_author_id: author.id)
      p2.save

      author.parity_post_ids.map(&.as(Int64)).sort.should eq [p1.id, p2.id].compact.sort
    end

    it "assigns the collection by ids (points listed records, nullifies the rest)" do
      author = ParityAuthor.new(name: "Ann")
      author.save

      p1 = ParityPost.new(title: "A", parity_author_id: author.id)
      p1.save
      p2 = ParityPost.new(title: "B", parity_author_id: author.id)
      p2.save
      orphan = ParityPost.new(title: "C")
      orphan.save

      author.parity_post_ids = [p1.id, orphan.id]

      author.parity_post_ids.map(&.as(Int64)).sort.should eq [p1.id, orphan.id].compact.sort

      # p2 was dropped from the set, so its FK is nullified
      ParityPost.find!(p2.id).parity_author_id.should be_nil
      # orphan now belongs to the author
      ParityPost.find!(orphan.id).parity_author_id.should eq author.id
    end
  end

  describe "dependent: :restrict_with_exception" do
    it "raises RestrictError when dependent records exist" do
      author = ParityAuthor.new(name: "Ann")
      author.save
      ParityPost.new(title: "A", parity_author_id: author.id).save

      expect_raises(Grant::Associations::RestrictError, /dependent guarded_posts/) do
        author.destroy
      end

      # The author was not deleted
      ParityAuthor.find(author.id).should_not be_nil
    end

    it "allows destroy when there are no dependent records" do
      author = ParityAuthor.new(name: "Ann")
      author.save

      author.destroy.should be_truthy
      ParityAuthor.find(author.id).should be_nil
    end
  end

  describe "lambda association scope" do
    it "returns only records matching the scope" do
      author = ParityAuthor.new(name: "Ann")
      author.save

      ParityPost.new(title: "pub1", published: true, parity_author_id: author.id).save
      ParityPost.new(title: "pub2", published: true, parity_author_id: author.id).save
      ParityPost.new(title: "draft", published: false, parity_author_id: author.id).save

      author.parity_posts.size.should eq 3
      author.published_parity_posts.size.should eq 2
      author.published_parity_posts.all?(&.published).should be_true
    end

    it "composes the scope with additional clauses" do
      author = ParityAuthor.new(name: "Ann")
      author.save
      ParityPost.new(title: "keep", published: true, parity_author_id: author.id).save
      ParityPost.new(title: "skip", published: true, parity_author_id: author.id).save

      results = author.published_parity_posts.all("AND parity_posts.title = ?", ["keep"])
      results.map(&.title).should eq ["keep"]
    end
  end

  describe "has_one :through with source:" do
    it "resolves the target through the named source association" do
      history = ParityAccountHistory.new(note: "v1")
      history.save

      supplier = ParitySupplier.new(name: "Acme")
      supplier.save

      account = ParityAccount.new(parity_supplier_id: supplier.id, parity_history_id: history.id)
      account.save

      resolved = supplier.latest_history
      resolved.should_not be_nil
      resolved.not_nil!.id.should eq history.id
      resolved.not_nil!.note.should eq "v1"
    end
  end

  describe "AssociationRegistry population" do
    it "registers has_many metadata" do
      meta = Grant::AssociationRegistry.get("ParityAuthor", "parity_posts")
      meta.should_not be_nil
      meta.not_nil![:type].should eq :has_many
      meta.not_nil![:target_class].should eq ParityPost
      meta.not_nil![:foreign_key].should eq "parity_author_id"
    end

    it "registers belongs_to metadata" do
      meta = Grant::AssociationRegistry.get("ParityPost", "parity_author")
      meta.should_not be_nil
      meta.not_nil![:type].should eq :belongs_to
      meta.not_nil![:target_class].should eq ParityAuthor
    end

    it "registers has_one :through metadata" do
      meta = Grant::AssociationRegistry.get("ParitySupplier", "latest_history")
      meta.should_not be_nil
      meta.not_nil![:type].should eq :has_one
      meta.not_nil![:through].should eq "parity_accounts"
    end
  end
end
