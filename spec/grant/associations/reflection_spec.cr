require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class RfAuthor < Grant::Base
    connection {{ adapter_literal }}
    table rf_authors
    column id : Int64, primary: true
    column name : String
    has_many :rf_books, class_name: RfBook, foreign_key: :rf_author_id, dependent: :destroy
    has_many :rf_reviews, class_name: RfReview, through: :rf_books, source: :rf_reviews
    has_one :rf_profile, class_name: RfProfile, foreign_key: :rf_author_id, inverse_of: false
    has_many :rf_notes, as: :annotatable, class_name: RfNote, dependent: :destroy
    has_many :rf_recent_books, -> { order(id: :desc) }, class_name: RfBook, foreign_key: :rf_author_id, strict_loading: true
  end

  class RfBook < Grant::Base
    connection {{ adapter_literal }}
    table rf_books
    column id : Int64, primary: true
    column title : String
    column rf_author_id : Int64?
    belongs_to :rf_author, class_name: RfAuthor, foreign_key: :rf_author_id, optional: true
    has_many :rf_reviews, class_name: RfReview, foreign_key: :rf_book_id
  end

  class RfReview < Grant::Base
    connection {{ adapter_literal }}
    table rf_reviews
    column id : Int64, primary: true
    column stars : Int32 = 0
    column rf_book_id : Int64?
    belongs_to :rf_book, class_name: RfBook, foreign_key: :rf_book_id, optional: true
  end

  class RfProfile < Grant::Base
    connection {{ adapter_literal }}
    table rf_profiles
    column id : Int64, primary: true
    column rf_author_id : Int64?
    belongs_to :rf_author, class_name: RfAuthor, foreign_key: :rf_author_id, optional: true
  end

  class RfNote < Grant::Base
    connection {{ adapter_literal }}
    table rf_notes
    column id : Int64, primary: true
    column body : String
    belongs_to :annotatable, polymorphic: true, optional: true
  end
{% end %}

describe "association reflection" do
  it "describes a has_many" do
    reflection = RfAuthor.reflect_on_association(:rf_books).not_nil!
    reflection.name.should eq("rf_books")
    reflection.macro.should eq(:has_many)
    reflection.klass.should eq(RfBook)
    reflection.class_name.should eq("RfBook")
    reflection.active_record.should eq(RfAuthor)
    reflection.foreign_key.should eq("rf_author_id")
    reflection.primary_key.should eq("id")
    reflection.collection?.should be_true
    reflection.polymorphic?.should be_false
    reflection.through?.should be_false
    reflection.scope?.should be_false
    reflection.dependent.should eq(:destroy)
    reflection.options["dependent"].should eq(":destroy")
  end

  it "describes a belongs_to and a has_one" do
    belongs = RfBook.reflect_on_association("rf_author").not_nil!
    belongs.macro.should eq(:belongs_to)
    belongs.klass.should eq(RfAuthor)
    belongs.foreign_key.should eq("rf_author_id")
    belongs.collection?.should be_false

    has_one = RfAuthor.reflect_on_association(:rf_profile).not_nil!
    has_one.macro.should eq(:has_one)
    has_one.has_one?.should be_true
    has_one.klass.should eq(RfProfile)
  end

  it "returns nil for an unknown association" do
    RfAuthor.reflect_on_association(:nope).should be_nil
  end

  it "enumerates every association in declaration order, optionally by macro" do
    RfAuthor.reflect_on_all_associations.map(&.name).should eq(
      ["rf_books", "rf_reviews", "rf_profile", "rf_notes", "rf_recent_books"])
    RfAuthor.reflect_on_all_associations(:has_many).map(&.name).should eq(
      ["rf_books", "rf_reviews", "rf_notes", "rf_recent_books"])
    RfAuthor.reflect_on_all_associations(:belongs_to).should be_empty
    RfBook.reflect_on_all_associations(:belongs_to).map(&.name).should eq(["rf_author"])
  end

  it "resolves the through and source reflections" do
    reflection = RfAuthor.reflect_on_association(:rf_reviews).not_nil!
    reflection.through?.should be_true
    reflection.through_reflection.not_nil!.name.should eq("rf_books")
    reflection.source_reflection.not_nil!.name.should eq("rf_reviews")
    reflection.source_reflection.not_nil!.klass.should eq(RfReview)
  end

  it "registers polymorphic associations on both sides" do
    belongs = RfNote.reflect_on_association(:annotatable).not_nil!
    belongs.macro.should eq(:belongs_to)
    belongs.polymorphic?.should be_true
    belongs.foreign_key.should eq("annotatable_id")
    belongs.foreign_type.should eq("annotatable_type")
    expect_raises(ArgumentError, /no single target class/) { belongs.klass }

    has_many = RfAuthor.reflect_on_association(:rf_notes).not_nil!
    has_many.polymorphic_as.should eq("annotatable")
    has_many.foreign_type.should eq("annotatable_type")
    has_many.foreign_key.should eq("annotatable_id")
    has_many.klass.should eq(RfNote)
    has_many.polymorphic?.should be_false
  end

  it "reports scopes and the strict_loading option" do
    reflection = RfAuthor.reflect_on_association(:rf_recent_books).not_nil!
    reflection.scope?.should be_true
    reflection.strict_loading?.should be_true
    RfAuthor.reflect_on_association(:rf_books).not_nil!.strict_loading?.should be_false
  end

  it "reports explicit, detected, and disabled inverses" do
    RfAuthor.reflect_on_association(:rf_books).not_nil!.inverse_of.not_nil!.name.should eq("rf_author")
    RfBook.reflect_on_association(:rf_author).not_nil!.inverse_of.should be_nil
    RfAuthor.reflect_on_association(:rf_profile).not_nil!.inverse_of.should be_nil
    RfAuthor.reflect_on_association(:rf_recent_books).not_nil!.inverse_of.should be_nil
  end

  it "keeps the registry lookup working" do
    meta = Grant::AssociationRegistry.get("RfAuthor", "rf_books").not_nil!
    meta[:type].should eq(:has_many)
    meta[:target_class].should eq(RfBook)
    meta[:foreign_key].should eq("rf_author_id")
  end

  it "names an unknown association in Model#association" do
    author = RfAuthor.new(name: "x")
    expect_raises(Grant::AssociationNotFoundError, /'nope' was not found on RfAuthor/) { author.association(:nope) }
    author.association(:rf_books).reflection.macro.should eq(:has_many)
  end
end
