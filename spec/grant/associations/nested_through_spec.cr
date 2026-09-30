require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  # Author -> posts -> comments -> reader -> team: a through of a through,
  # then a through of that.
  class NtAuthor < Grant::Base
    connection {{ adapter_literal }}
    table nt_authors
    column id : Int64, primary: true
    column name : String
    has_many :nt_posts, class_name: NtPost, foreign_key: :nt_author_id
    has_many :nt_comments, through: :nt_posts, source: :nt_comments, class_name: NtComment
    has_many :nt_readers, through: :nt_comments, source: :nt_reader, class_name: NtReader
    has_many :nt_teams, through: :nt_readers, source: :nt_team, class_name: NtTeam
    has_many :nt_loud_readers, -> { where(loud: true) }, through: :nt_comments, source: :nt_reader, class_name: NtReader
  end

  class NtPost < Grant::Base
    connection {{ adapter_literal }}
    table nt_posts
    column id : Int64, primary: true
    column title : String
    column nt_author_id : Int64?
    has_many :nt_comments, class_name: NtComment, foreign_key: :nt_post_id
  end

  class NtComment < Grant::Base
    connection {{ adapter_literal }}
    table nt_comments
    column id : Int64, primary: true
    column nt_post_id : Int64?
    column nt_reader_id : Int64?
    belongs_to :nt_post, class_name: NtPost, foreign_key: :nt_post_id, optional: true
    belongs_to :nt_reader, class_name: NtReader, foreign_key: :nt_reader_id, optional: true
  end

  class NtReader < Grant::Base
    connection {{ adapter_literal }}
    table nt_readers
    column id : Int64, primary: true
    column name : String
    column loud : Bool = false
    column nt_team_id : Int64?
    belongs_to :nt_team, class_name: NtTeam, foreign_key: :nt_team_id, optional: true
  end

  class NtTeam < Grant::Base
    connection {{ adapter_literal }}
    table nt_teams
    column id : Int64, primary: true
    column name : String
  end
{% end %}

private def nt_reader(name : String, team : NtTeam? = nil, loud : Bool = false) : NtReader
  NtReader.create!(name: name, loud: loud, nt_team_id: team.try(&.id))
end

private def nt_comment(post : NtPost, reader : NtReader) : NtComment
  NtComment.create!(nt_post_id: post.id, nt_reader_id: reader.id)
end

# ada: posts p1, p2; ben: post p3. ann reads p1 and p2 (twice), bo reads p1,
# cy reads p3 only.
private def nt_fixture
  red = NtTeam.create!(name: "red")
  blue = NtTeam.create!(name: "blue")
  ada = NtAuthor.create!(name: "ada")
  ben = NtAuthor.create!(name: "ben")
  p1 = NtPost.create!(title: "p1", nt_author_id: ada.id)
  p2 = NtPost.create!(title: "p2", nt_author_id: ada.id)
  p3 = NtPost.create!(title: "p3", nt_author_id: ben.id)
  ann = nt_reader("ann", red, loud: true)
  bo = nt_reader("bo", blue)
  cy = nt_reader("cy", red, loud: true)
  [{p1, ann}, {p2, ann}, {p1, bo}, {p3, cy}].each { |post, reader| nt_comment(post, reader) }
  {ada, ben, ann, bo, cy, red, blue}
end

describe "nested has_many :through" do
  before_all do
    NtAuthor.migrator.drop_and_create
    NtPost.migrator.drop_and_create
    NtComment.migrator.drop_and_create
    NtReader.migrator.drop_and_create
    NtTeam.migrator.drop_and_create
  end

  before_each do
    NtComment.clear
    NtPost.clear
    NtReader.clear
    NtTeam.clear
    NtAuthor.clear
  end

  it "reads a through association that goes through another through" do
    ada, ben, ann, bo, cy = nt_fixture
    ada.nt_readers.to_a.map(&.name).sort!.should eq ["ann", "bo"]
    ben.nt_readers.to_a.map(&.name).should eq ["cy"]
    ada.nt_comments.to_a.size.should eq 3
    ann.id.should_not be_nil
    bo.id.should_not be_nil
    cy.id.should_not be_nil
  end

  it "lists each target once even when several paths reach it" do
    ada, _ = nt_fixture
    ada.nt_readers.to_a.map(&.name).count("ann").should eq 1
    ada.nt_readers.count.should eq 2
    ada.nt_readers.size.should eq 2
  end

  it "reads the whole chain with one statement" do
    ada, _ = nt_fixture
    statements = AssociationQueryCounter.statements { ada.nt_readers.to_a }
    statements.size.should eq 1
    statements.first.should contain("JOIN")
  end

  it "goes three links deep through two through associations" do
    ada, ben = nt_fixture
    ada.nt_teams.to_a.map(&.name).sort!.should eq ["blue", "red"]
    ben.nt_teams.to_a.map(&.name).should eq ["red"]
    fresh = NtAuthor.find!(ada.id)
    AssociationQueryCounter.statements { fresh.nt_teams.to_a }.size.should eq 1
  end

  it "supports the collection readers on a nested through" do
    ada, ben, ann = nt_fixture
    ada.nt_readers.exists?.should be_true
    ada.nt_readers.any?.should be_true
    ada.nt_readers.empty?.should be_false
    NtAuthor.create!(name: "lone").nt_readers.empty?.should be_true
    ada.nt_readers.where(name: "ann").to_a.map(&.id).should eq [ann.id]
    ada.nt_readers.find(ann.id).try(&.name).should eq "ann"
    ada.nt_readers.find_by(name: "cy").should be_nil
    ada.nt_readers.ids.map(&.to_s).sort!.should eq ada.nt_readers.to_a.map(&.id.to_s).sort!
    ada.nt_readers.all("AND nt_readers.name = ?", ["bo"]).map(&.name).should eq ["bo"]
    ben.nt_readers.first.try(&.name).should eq "cy"
  end

  it "applies an association scope to the targets" do
    ada, _ = nt_fixture
    ada.nt_loud_readers.to_a.map(&.name).should eq ["ann"]
  end

  it "preloads with one query per hop, never per owner" do
    nt_fixture
    statements = AssociationQueryCounter.statements do
      authors = NtAuthor.includes(:nt_readers).select.to_a
      authors.map { |author| author.nt_readers.to_a.map(&.name).sort! }.should eq [["ann", "bo"], ["cy"]]
    end
    # authors, posts, comments, readers
    statements.size.should eq 4
  end

  it "preloads the same records the lazy reader returns" do
    nt_fixture
    lazy = NtAuthor.order(:id).select.to_a.map { |author| author.nt_readers.to_a.map(&.id.not_nil!).sort! }
    preloaded = NtAuthor.includes(:nt_readers).order(:id).select.to_a.map do |author|
      author.association_loaded?(:nt_readers).should be_true
      author.nt_readers.to_a.map(&.id.not_nil!).sort!
    end
    preloaded.should eq lazy
  end

  it "preloads a chain of three links" do
    nt_fixture
    statements = AssociationQueryCounter.statements do
      NtAuthor.includes(:nt_teams).order(:id).select.to_a.map { |author| author.nt_teams.to_a.map(&.name).sort! }.should eq [["blue", "red"], ["red"]]
    end
    # authors, posts, comments, readers, teams
    statements.size.should eq 5
  end

  it "reloads through the same chain" do
    ada, _ = nt_fixture
    ada.nt_readers.to_a.size.should eq 2
    nt_comment(NtPost.where(title: "p1").first!, nt_reader("dee"))
    ada.reload_nt_readers.to_a.map(&.name).sort!.should eq ["ann", "bo", "dee"]
  end

  it "is read-only, as in ActiveRecord" do
    ada, _, ann = nt_fixture
    expect_raises(Grant::Associations::ThroughWriteError, /read-only/) { ada.nt_readers << ann }
    expect_raises(Grant::Associations::ThroughWriteError, /read-only/) { ada.nt_readers.delete_all }
  end
end
