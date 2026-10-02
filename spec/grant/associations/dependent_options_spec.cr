require "../../spec_helper"
require "../../support/crystal_compiler"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class DepOwner < Grant::Base
    connection {{ adapter_literal }}
    table dep_owners
    column id : Int64, primary: true
    column name : String?

    has_many :dep_notes, class_name: DepNote, foreign_key: :dep_owner_id, dependent: :restrict_with_error
    has_many :dep_old_notes, class_name: DepOldNote, foreign_key: :dep_owner_id, dependent: :restrict
    has_one :dep_profile, class_name: DepProfile, foreign_key: :dep_owner_id, dependent: :restrict_with_error
    has_many :dep_kids, class_name: DepKid, foreign_key: :dep_owner_id, dependent: :destroy
    has_many :dep_guarded, class_name: DepGuarded, foreign_key: :dep_owner_id, dependent: :restrict_with_exception
  end

  class DepNote < Grant::Base
    connection {{ adapter_literal }}
    table dep_notes
    column id : Int64, primary: true
    column dep_owner_id : Int64?
  end

  class DepOldNote < Grant::Base
    connection {{ adapter_literal }}
    table dep_old_notes
    column id : Int64, primary: true
    column dep_owner_id : Int64?
  end

  class DepProfile < Grant::Base
    connection {{ adapter_literal }}
    table dep_profiles
    column id : Int64, primary: true
    column dep_owner_id : Int64?
  end

  class DepGuarded < Grant::Base
    connection {{ adapter_literal }}
    table dep_guardeds
    column id : Int64, primary: true
    column dep_owner_id : Int64?
  end

  class DepKid < Grant::Base
    connection {{ adapter_literal }}
    table dep_kids
    column id : Int64, primary: true
    column dep_owner_id : Int64?

    @@seen = [] of String?

    def self.seen : Array(String?)
      @@seen
    end

    before_destroy do
      @@seen << destroyed_by_association.try(&.name)
    end
  end

  class DepAsyncOwner < Grant::Base
    connection {{ adapter_literal }}
    table dep_async_owners
    column id : Int64, primary: true
    column name : String?
    has_many :dep_async_kids, class_name: DepAsyncKid, foreign_key: :dep_async_owner_id, dependent: :destroy_async
    has_one :dep_async_card, class_name: DepAsyncCard, foreign_key: :dep_async_owner_id, dependent: :destroy_async
  end

  class DepAsyncKid < Grant::Base
    connection {{ adapter_literal }}
    table dep_async_kids
    column id : Int64, primary: true
    column dep_async_owner_id : Int64?

    @@seen = [] of String?

    def self.seen : Array(String?)
      @@seen
    end

    before_destroy do
      @@seen << destroyed_by_association.try(&.name)
    end
  end

  class DepAsyncCard < Grant::Base
    connection {{ adapter_literal }}
    table dep_async_cards
    column id : Int64, primary: true
    column dep_async_owner_id : Int64?
  end

  class DepPost < Grant::Base
    connection {{ adapter_literal }}
    table dep_posts
    column id : Int64, primary: true
    column name : String?
    has_many :dep_taggings, class_name: DepTagging, foreign_key: :dep_post_id
    has_many :dep_tags, class_name: DepTag, through: :dep_taggings, dependent: :destroy
  end

  class DepShelf < Grant::Base
    connection {{ adapter_literal }}
    table dep_shelves
    column id : Int64, primary: true
    column name : String?
    has_many :dep_shelf_taggings, class_name: DepShelfTagging, foreign_key: :dep_shelf_id
    has_many :dep_tags, class_name: DepTag, through: :dep_shelf_taggings, source: :dep_tag, dependent: :restrict_with_error
  end

  class DepTag < Grant::Base
    connection {{ adapter_literal }}
    table dep_tags
    column id : Int64, primary: true
    column label : String?
  end

  class DepTagging < Grant::Base
    connection {{ adapter_literal }}
    table dep_taggings
    column id : Int64, primary: true
    column dep_post_id : Int64?
    column dep_tag_id : Int64?
    belongs_to :dep_post, class_name: DepPost, foreign_key: dep_post_id : Int64?, optional: true
    belongs_to :dep_tag, class_name: DepTag, foreign_key: dep_tag_id : Int64?, optional: true
  end

  class DepShelfTagging < Grant::Base
    connection {{ adapter_literal }}
    table dep_shelf_taggings
    column id : Int64, primary: true
    column dep_shelf_id : Int64?
    column dep_tag_id : Int64?
    belongs_to :dep_shelf, class_name: DepShelf, foreign_key: dep_shelf_id : Int64?, optional: true
    belongs_to :dep_tag, class_name: DepTag, foreign_key: dep_tag_id : Int64?, optional: true
  end

  class DepParent < Grant::Base
    connection {{ adapter_literal }}
    table dep_parents
    column id : Int64, primary: true
    column name : String?

    @@destroy_calls = 0

    def self.destroy_calls : Int32
      @@destroy_calls
    end

    after_destroy do
      @@destroy_calls += 1
    end
  end

  class DepChildDestroy < Grant::Base
    connection {{ adapter_literal }}
    table dep_child_destroys
    column id : Int64, primary: true
    column dep_parent_id : Int64?
    belongs_to :dep_parent, class_name: DepParent, foreign_key: dep_parent_id : Int64?, dependent: :destroy, optional: true
  end

  class DepChildDelete < Grant::Base
    connection {{ adapter_literal }}
    table dep_child_deletes
    column id : Int64, primary: true
    column dep_parent_id : Int64?
    belongs_to :dep_parent, class_name: DepParent, foreign_key: dep_parent_id : Int64?, dependent: :delete, optional: true
  end

  class DepChildAsync < Grant::Base
    connection {{ adapter_literal }}
    table dep_child_asyncs
    column id : Int64, primary: true
    column dep_parent_id : Int64?
    belongs_to :dep_parent, class_name: DepParent, foreign_key: dep_parent_id : Int64?, dependent: :destroy_async, optional: true
  end
{% end %}

private def compile_dependent_source(body : String) : Tuple(Bool, String)
  repo_root = File.expand_path("../../..", __DIR__)
  source = <<-CR
    require "sqlite3"
    require "../../../src/grant"
    require "../../../src/adapter/sqlite"

    class DepCompileThing < Grant::Base
      connection sqlite
      table dep_compile_things
      column id : Int64, primary: true
      column dep_compile_owner_id : Int64?
    end

    class DepCompileOwner < Grant::Base
      connection sqlite
      table dep_compile_owners
      column id : Int64, primary: true
    #{body}
    end
    CR
  file = File.new(File.join(__DIR__, "dep_compile_check_#{Process.pid}.cr"), "w")
  file.print(source)
  file.close
  begin
    error = IO::Memory.new
    status = Process.run(spec_crystal_compiler, ["build", "--no-codegen", "--no-color", file.path], error: error, output: Process::Redirect::Close, chdir: repo_root)
    {status.success?, error.to_s}
  ensure
    file.delete
  end
end

describe "dependent options" do
  before_all do
    DepOwner.migrator.drop_and_create
    DepNote.migrator.drop_and_create
    DepOldNote.migrator.drop_and_create
    DepProfile.migrator.drop_and_create
    DepGuarded.migrator.drop_and_create
    DepKid.migrator.drop_and_create
    DepAsyncOwner.migrator.drop_and_create
    DepAsyncKid.migrator.drop_and_create
    DepAsyncCard.migrator.drop_and_create
    DepPost.migrator.drop_and_create
    DepShelf.migrator.drop_and_create
    DepTag.migrator.drop_and_create
    DepTagging.migrator.drop_and_create
    DepShelfTagging.migrator.drop_and_create
    DepParent.migrator.drop_and_create
    DepChildDestroy.migrator.drop_and_create
    DepChildDelete.migrator.drop_and_create
    DepChildAsync.migrator.drop_and_create
  end

  before_each do
    DepNote.clear
    DepOldNote.clear
    DepProfile.clear
    DepGuarded.clear
    DepKid.clear
    DepOwner.clear
    DepAsyncKid.clear
    DepAsyncCard.clear
    DepAsyncOwner.clear
    DepChildDestroy.clear
    DepChildDelete.clear
    DepChildAsync.clear
    DepTagging.clear
    DepShelfTagging.clear
    DepTag.clear
    DepPost.clear
    DepShelf.clear
    DepParent.clear
    DepKid.seen.clear
    DepAsyncKid.seen.clear
  end

  describe "unknown values" do
    it "are compile errors" do
      ok, message = compile_dependent_source("  has_many :dep_compile_things, class_name: DepCompileThing, foreign_key: :dep_compile_owner_id, dependent: :bogus")
      ok.should be_false
      message.should contain("Unknown `dependent: :bogus`")
      message.should contain("dep_compile_things")
    end

    it "reject a value the association type does not support" do
      ok, message = compile_dependent_source("  has_many :dep_compile_things, class_name: DepCompileThing, foreign_key: :dep_compile_owner_id, dependent: :delete")
      ok.should be_false
      message.should contain("Unknown `dependent: :delete`")

      ok, message = compile_dependent_source("  has_one :dep_compile_thing, class_name: DepCompileThing, foreign_key: :dep_compile_owner_id, dependent: :delete_all")
      ok.should be_false
      message.should contain("Unknown `dependent: :delete_all`")
    end

    it "reject belongs_to values other than destroy, delete and destroy_async" do
      ok, message = compile_dependent_source("  belongs_to :dep_compile_thing, class_name: DepCompileThing, foreign_key: dep_compile_thing_id : Int64?, dependent: :nullify")
      ok.should be_false
      message.should contain("Unknown `dependent: :nullify`")
    end

    it "accept every supported spelling" do
      ok, message = compile_dependent_source(<<-CR)
          has_many :dep_compile_things, class_name: DepCompileThing, foreign_key: :dep_compile_owner_id, dependent: :restrict_with_error
          has_one :dep_compile_thing, class_name: DepCompileThing, foreign_key: :dep_compile_owner_id, dependent: :destroy_async
        CR
      ok.should be_true, message
    end
  end

  describe "restrict_with_error" do
    it "blocks the destroy and adds an error when dependents exist" do
      owner = DepOwner.create!(name: "o")
      DepNote.create!(dep_owner_id: owner.id)

      owner.destroy.should be_false

      DepOwner.find(owner.id).should_not be_nil
      owner.errors.map(&.to_s).should contain("Cannot delete record because of dependent dep_notes")
    end

    it "destroys the owner when there are no dependents" do
      owner = DepOwner.create!(name: "o")

      owner.destroy.should be_true
      DepOwner.find(owner.id).should be_nil
    end

    it "words the has_one message in the singular" do
      owner = DepOwner.create!(name: "o")
      DepProfile.create!(dep_owner_id: owner.id)

      owner.destroy.should be_false
      owner.errors.map(&.to_s).should contain("Cannot delete record because a dependent dep_profile exists")
    end

    it "keeps :restrict as an alias" do
      owner = DepOwner.create!(name: "o")
      DepOldNote.create!(dep_owner_id: owner.id)

      owner.destroy.should be_false
      owner.errors.map(&.to_s).should contain("Cannot delete record because of dependent dep_old_notes")
    end
  end

  describe "restrict_with_exception" do
    it "raises and is reachable as Grant::DeleteRestrictionError" do
      owner = DepOwner.create!(name: "o")
      DepGuarded.create!(dep_owner_id: owner.id)

      expect_raises(Grant::DeleteRestrictionError, /dependent dep_guarded/) { owner.destroy }
      DepOwner.find(owner.id).should_not be_nil
    end
  end

  describe "has_many through" do
    it "dependent: :destroy removes the join rows and keeps the associated records" do
      post = DepPost.create!(name: "p")
      tag = DepTag.create!(label: "t")
      DepTagging.create!(dep_post_id: post.id, dep_tag_id: tag.id)

      post.destroy.should be_true

      DepTagging.count.should eq(0)
      DepTag.find(tag.id).should_not be_nil
    end

    it "restrict_with_error blocks the destroy while associated records exist" do
      shelf = DepShelf.create!(name: "s")
      tag = DepTag.create!(label: "t")
      DepShelfTagging.create!(dep_shelf_id: shelf.id, dep_tag_id: tag.id)

      shelf.destroy.should be_false
      shelf.errors.map(&.to_s).should contain("Cannot delete record because of dependent dep_tags")
      DepShelf.find(shelf.id).should_not be_nil
    end
  end

  describe "destroyed_by_association" do
    it "is set on children destroyed by dependent: :destroy" do
      owner = DepOwner.create!(name: "o")
      DepKid.create!(dep_owner_id: owner.id)
      DepKid.create!(dep_owner_id: owner.id)

      owner.destroy.should be_true

      DepKid.seen.should eq(["dep_kids", "dep_kids"])
      DepKid.count.should eq(0)
    end

    it "is nil for a record destroyed directly" do
      kid = DepKid.create!
      kid.destroy
      DepKid.seen.should eq([nil] of String?)
      kid.destroyed_by_association.should be_nil
    end
  end

  describe "destroy_async" do
    it "enqueues one job per association and destroys the dependents when it runs" do
      jobs = [] of Grant::Dependent::AsyncDestroyJob
      Grant::Dependent.async_destroy_enqueuer = ->(job : Grant::Dependent::AsyncDestroyJob) do
        jobs << job
        nil
      end

      begin
        owner = DepAsyncOwner.create!
        3.times { DepAsyncKid.create!(dep_async_owner_id: owner.id) }
        DepAsyncCard.create!(dep_async_owner_id: owner.id)

        owner.destroy.should be_true

        jobs.map(&.association).sort!.should eq(["dep_async_card", "dep_async_kids"])
        DepAsyncKid.count.should eq(3)

        kids_job = jobs.find! { |job| job.association == "dep_async_kids" }
        kids_job.perform.should eq(3)
        DepAsyncKid.count.should eq(0)
        DepAsyncKid.seen.should eq(["dep_async_kids", "dep_async_kids", "dep_async_kids"])

        # Running it again finds nothing.
        kids_job.perform.should eq(0)

        jobs.find! { |job| job.association == "dep_async_card" }.perform.should eq(1)
        DepAsyncCard.count.should eq(0)
      ensure
        Grant::Dependent.reset_async_destroy_enqueuer
      end
    end

    it "does nothing while the owner still exists" do
      jobs = [] of Grant::Dependent::AsyncDestroyJob
      Grant::Dependent.async_destroy_enqueuer = ->(job : Grant::Dependent::AsyncDestroyJob) do
        jobs << job
        nil
      end

      begin
        owner = DepAsyncOwner.create!
        DepAsyncKid.create!(dep_async_owner_id: owner.id)
        job = Grant::Dependent::AsyncDestroyJob.new(DepAsyncOwner.name, "dep_async_kids", owner.id.not_nil!)

        job.perform.should eq(0)
        DepAsyncKid.count.should eq(1)
      ensure
        Grant::Dependent.reset_async_destroy_enqueuer
      end
    end

    it "enqueues nothing when the destroy rolls back" do
      jobs = [] of Grant::Dependent::AsyncDestroyJob
      Grant::Dependent.async_destroy_enqueuer = ->(job : Grant::Dependent::AsyncDestroyJob) do
        jobs << job
        nil
      end

      begin
        owner = DepAsyncOwner.create!
        DepAsyncKid.create!(dep_async_owner_id: owner.id)

        DepAsyncOwner.transaction do
          owner.destroy
          raise Grant::Transaction::Rollback.new
        end

        jobs.should be_empty
        DepAsyncOwner.find(owner.id).should_not be_nil
      ensure
        Grant::Dependent.reset_async_destroy_enqueuer
      end
    end

    it "runs in a fiber with the default enqueuer" do
      owner = DepAsyncOwner.create!
      2.times { DepAsyncKid.create!(dep_async_owner_id: owner.id) }

      owner.destroy.should be_true
      # Wait up to 5 seconds: on a loaded CI runner the fiber can need more
      # than the 200 ms this allowed before.
      500.times do
        break if DepAsyncKid.count == 0
        sleep 10.milliseconds
      end

      DepAsyncKid.count.should eq(0)
    end
  end

  describe "belongs_to dependent" do
    it ":destroy destroys the parent after the child, with callbacks" do
      parent = DepParent.create!(name: "p")
      child = DepChildDestroy.create!(dep_parent_id: parent.id)
      calls = DepParent.destroy_calls

      child.destroy.should be_true

      DepParent.find(parent.id).should be_nil
      DepParent.destroy_calls.should eq(calls + 1)
    end

    it ":delete removes the parent without its callbacks" do
      parent = DepParent.create!(name: "p")
      child = DepChildDelete.create!(dep_parent_id: parent.id)
      calls = DepParent.destroy_calls

      child.destroy.should be_true

      DepParent.find(parent.id).should be_nil
      DepParent.destroy_calls.should eq(calls)
    end

    it ":destroy_async queues the parent's destroy" do
      jobs = [] of Grant::Dependent::AsyncDestroyJob
      Grant::Dependent.async_destroy_enqueuer = ->(job : Grant::Dependent::AsyncDestroyJob) do
        jobs << job
        nil
      end

      begin
        parent = DepParent.create!(name: "p")
        child = DepChildAsync.create!(dep_parent_id: parent.id)

        child.destroy.should be_true
        DepParent.find(parent.id).should_not be_nil
        jobs.size.should eq(1)

        jobs.first.perform.should eq(1)
        DepParent.find(parent.id).should be_nil
        jobs.first.perform.should eq(0)
      ensure
        Grant::Dependent.reset_async_destroy_enqueuer
      end
    end

    it "does nothing for a child without a parent" do
      child = DepChildDestroy.create!
      child.destroy.should be_true
    end
  end
end
