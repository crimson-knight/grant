require "../spec_helper"
require "../support/statement_recorder"
require "../../src/grant/test_fixtures"
require "../../src/grant/spec_support/transactional"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class FxAuthor < Grant::Base
    connection {{ adapter_literal }}
    table fx_authors

    column id : Int64, primary: true
    column email : String
    column admin : Bool?
    timestamps
  end

  class FxPost < Grant::Base
    connection {{ adapter_literal }}
    table fx_posts

    column id : Int64, primary: true
    column title : String
    belongs_to author : FxAuthor
    timestamps
  end
{% end %}

Grant::TestFixtures.fixtures fx_authors: FxAuthor, fx_posts: FxPost

private FIXTURE_DIR = File.join(Dir.tempdir, "grant_fixtures_spec_#{Process.pid}")

private def write_fixtures
  Dir.mkdir_p(FIXTURE_DIR)
  File.write(File.join(FIXTURE_DIR, "fx_authors.yml"), <<-YAML)
    DEFAULTS: &defaults
      admin: false
    alice:
      <<: *defaults
      email: alice@example.com
      admin: true
    bob:
      <<: *defaults
      email: bob@example.com
    cara:
      email: cara@example.com
      id: 4242
    YAML
  File.write(File.join(FIXTURE_DIR, "fx_posts.yml"), <<-YAML)
    hello:
      title: Hello
      author: alice
    second:
      title: Second
      author: bob
    YAML
end

describe Grant::TestFixtures do
  before_all do
    FxAuthor.migrator.drop_and_create
    FxPost.migrator.drop_and_create
    write_fixtures
  end

  after_all do
    FxPost.migrator.drop
    FxAuthor.migrator.drop
    Dir.glob(File.join(FIXTURE_DIR, "*")).each { |path| File.delete(path) }
    Dir.delete(FIXTURE_DIR)
  end

  before_each do
    FxPost.clear
    FxAuthor.clear
  end

  describe ".identify" do
    it "hashes the label to a stable id below MAX_ID" do
      Grant::TestFixtures.identify(:alice).should eq(Digest::CRC32.checksum("alice").to_i64 % Grant::TestFixtures::MAX_ID)
      Grant::TestFixtures.identify("alice").should eq(Grant::TestFixtures.identify(:alice))
      Grant::TestFixtures.identify(:alice).should_not eq(Grant::TestFixtures.identify(:bob))
      Grant::TestFixtures.identify("anything at all").should be < Grant::TestFixtures::MAX_ID
    end

    it "derives a stable v5 UUID" do
      Grant::TestFixtures.identify_uuid(:alice).should eq(Grant::TestFixtures.identify_uuid("alice"))
      Grant::TestFixtures.identify_uuid(:alice).version.should eq(UUID::Version::V5)
    end
  end

  describe ".load" do
    it "inserts the labeled rows with hashed ids and fills the timestamps" do
      Grant::TestFixtures.load(FIXTURE_DIR)

      FxAuthor.count.should eq(3)
      alice = FxAuthor.find!(Grant::TestFixtures.identify(:alice))
      alice.email.should eq("alice@example.com")
      alice.admin.should be_true
      alice.created_at.should_not be_nil
      alice.updated_at.should_not be_nil
      FxAuthor.find!(Grant::TestFixtures.identify(:bob)).admin.should be_false
    end

    it "keeps an explicit id" do
      Grant::TestFixtures.load(FIXTURE_DIR)

      FxAuthor.find!(4242).email.should eq("cara@example.com")
      FxAuthor.find(Grant::TestFixtures.identify(:cara)).should be_nil
    end

    it "resolves a belongs_to label to the foreign key" do
      Grant::TestFixtures.load(FIXTURE_DIR)

      FxPost.find!(Grant::TestFixtures.identify(:hello)).author_id.should eq(Grant::TestFixtures.identify(:alice))
      FxPost.find!(Grant::TestFixtures.identify(:second)).author_id.should eq(Grant::TestFixtures.identify(:bob))
    end

    it "runs one bulk INSERT per table" do
      statements = StatementRecorder.statements { Grant::TestFixtures.load(FIXTURE_DIR) }

      StatementRecorder.count(statements, "INSERT INTO", "fx_authors").should eq(1)
      StatementRecorder.count(statements, "INSERT INTO", "fx_posts").should eq(1)
      authors_insert = statements.find! { |sql| sql.starts_with?("INSERT INTO") && sql.includes?("fx_authors") }
      authors_insert.scan(/\(\s*[$?]/).size.should eq(3)
    end

    it "replaces existing rows so a second load leaves the same data" do
      FxAuthor.create!(email: "stale@example.com")

      Grant::TestFixtures.load(FIXTURE_DIR)
      Grant::TestFixtures.load(FIXTURE_DIR)

      FxAuthor.count.should eq(3)
      FxAuthor.where(email: "stale@example.com").count.should eq(0)
    end

    it "loads only the named sets" do
      Grant::TestFixtures.load(FIXTURE_DIR, only: ["fx_authors"])

      FxAuthor.count.should eq(3)
      FxPost.count.should eq(0)
    end

    it "raises Error for a set without a file" do
      expect_raises(Grant::TestFixtures::Error, /not found/) do
        Grant::TestFixtures.load(File.join(FIXTURE_DIR, "nowhere"))
      end
    end
  end

  describe "accessors" do
    it "return the record for a symbol or string label" do
      Grant::TestFixtures.load(FIXTURE_DIR)

      fx_authors(:alice).email.should eq("alice@example.com")
      fx_authors("bob").email.should eq("bob@example.com")
      fx_posts(:hello).author.not_nil!.email.should eq("alice@example.com")
    end

    it "raise RecordNotFound for an undefined label" do
      Grant::TestFixtures.load(FIXTURE_DIR)

      expect_raises(Grant::RecordNotFound) { fx_authors(:nobody) }
    end
  end

  describe "rollback through the test wrapper" do
    it "leaves no rows behind when loaded inside the wrapper" do
      Grant::Spec.within_transaction do
        Grant::TestFixtures.load(FIXTURE_DIR)
        FxAuthor.count.should eq(3)
        fx_authors(:alice).email.should eq("alice@example.com")
      end

      FxAuthor.count.should eq(0)
      FxPost.count.should eq(0)
    end

    it "lets an example change loaded rows without affecting the next one" do
      Grant::TestFixtures.load(FIXTURE_DIR)

      Grant::Spec.within_transaction do
        fx_authors(:alice).update!(email: "changed@example.com")
        FxAuthor.find!(Grant::TestFixtures.identify(:alice)).email.should eq("changed@example.com")
      end

      fx_authors(:alice).email.should eq("alice@example.com")
    end
  end
end
