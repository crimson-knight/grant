require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class IdAuthor < Grant::Base
    connection {{ adapter_literal }}
    table id_authors
    column id : Int64, primary: true
    column name : String
    has_many :id_books, class_name: IdBook, foreign_key: :id_author_id
    has_one :id_profile, class_name: IdProfile, foreign_key: :id_author_id
    has_many :id_scoped_books, -> { where(published: true) }, class_name: IdBook, foreign_key: :id_author_id
    has_many :id_opted_out_books, class_name: IdBook, foreign_key: :id_author_id, inverse_of: false
  end

  class IdBook < Grant::Base
    connection {{ adapter_literal }}
    table id_books
    column id : Int64, primary: true
    column title : String
    column published : Bool = false
    column id_author_id : Int64?
    belongs_to :id_author, class_name: IdAuthor, foreign_key: :id_author_id, optional: true
  end

  class IdProfile < Grant::Base
    connection {{ adapter_literal }}
    table id_profiles
    column id : Int64, primary: true
    column bio : String
    column id_author_id : Int64?
    belongs_to :id_author, class_name: IdAuthor, foreign_key: :id_author_id, optional: true
  end
{% end %}

describe "automatic inverse detection" do
  before_all do
    IdAuthor.migrator.drop_and_create
    IdBook.migrator.drop_and_create
    IdProfile.migrator.drop_and_create
  end

  before_each do
    IdBook.clear
    IdProfile.clear
    IdAuthor.clear
  end

  it "finds the inverse of has_many, has_one, and belongs_to without inverse_of" do
    IdAuthor.reflect_on_association(:id_books).not_nil!.inverse_of.not_nil!.name.should eq("id_author")
    IdAuthor.reflect_on_association(:id_profile).not_nil!.inverse_of.not_nil!.name.should eq("id_author")
    IdProfile.reflect_on_association(:id_author).not_nil!.inverse_of.not_nil!.name.should eq("id_profile")
  end

  it "does not pair a belongs_to with a has_many, a scoped association, or inverse_of: false" do
    IdBook.reflect_on_association(:id_author).not_nil!.inverse_of.should be_nil
    IdAuthor.reflect_on_association(:id_scoped_books).not_nil!.inverse_of.should be_nil
    IdAuthor.reflect_on_association(:id_opted_out_books).not_nil!.inverse_of.should be_nil
  end

  it "reuses the loaded owner when reading a lazily loaded has_many child's parent" do
    author = IdAuthor.create!(name: "a")
    IdBook.create!(title: "b", id_author_id: author.id)
    loaded = IdAuthor.find!(author.id)

    book = loaded.id_books.to_a.first
    book.association_loaded?(:id_author).should be_true
    AssociationQueryCounter.selects { book.id_author.should be(loaded) }.should eq(0)
  end

  it "removes the parent lookup N+1 after preloading a has_many" do
    2.times do |index|
      author = IdAuthor.create!(name: "author #{index}")
      3.times { |book| IdBook.create!(title: "book #{index}-#{book}", id_author_id: author.id) }
    end

    authors = IdAuthor.includes(:id_books).select.to_a
    AssociationQueryCounter.selects do
      authors.each do |author|
        author.id_books.each(&.id_author.should(be(author)))
      end
    end.should eq(0)
  end

  it "sets the has_one inverse when preloading and lazily reading" do
    author = IdAuthor.create!(name: "a")
    IdProfile.create!(bio: "bio", id_author_id: author.id)

    loaded = IdAuthor.includes(:id_profile).where(id: author.id).select.first
    profile = loaded.id_profile.not_nil!
    profile.association_loaded?(:id_author).should be_true
    AssociationQueryCounter.selects { profile.id_author.should be(loaded) }.should eq(0)

    lazy = IdAuthor.find!(author.id)
    lazy_profile = lazy.id_profile.not_nil!
    AssociationQueryCounter.selects { lazy_profile.id_author.should be(lazy) }.should eq(0)
  end

  it "sets the has_one inverse from the belongs_to side" do
    author = IdAuthor.create!(name: "a")
    IdProfile.create!(bio: "bio", id_author_id: author.id)

    profile = IdProfile.includes(:id_author).select.first
    owner = profile.id_author.not_nil!
    owner.association_loaded?(:id_profile).should be_true
    AssociationQueryCounter.selects { owner.id_profile.should be(profile) }.should eq(0)
  end

  it "does not set an inverse for scoped or opted-out associations" do
    author = IdAuthor.create!(name: "a")
    IdBook.create!(title: "b", published: true, id_author_id: author.id)

    scoped = IdAuthor.includes(:id_scoped_books).select.first.id_scoped_books.first!
    scoped.association_loaded?(:id_author).should be_false

    opted_out = IdAuthor.includes(:id_opted_out_books).select.first.id_opted_out_books.first!
    opted_out.association_loaded?(:id_author).should be_false
  end
end
