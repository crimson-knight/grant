require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CommitDedupSavepointModel < Grant::Base
    connection {{ adapter_literal }}
    table commit_dedup_savepoint_models

    column id : Int64, primary: true
    column name : String?

    class_property event_log : Array(String) = [] of String

    after_create_commit { CommitDedupSavepointModel.event_log << "create_commit" }
    after_update_commit { CommitDedupSavepointModel.event_log << "update_commit" }
    after_commit(on: :update) { CommitDedupSavepointModel.event_log << "commit_on_update" }
    after_commit { CommitDedupSavepointModel.event_log << "commit" }
    after_rollback(on: :destroy) { CommitDedupSavepointModel.event_log << "rollback_on_destroy" }
    after_rollback { CommitDedupSavepointModel.event_log << "rollback" }
  end
{% end %}

describe "commit callback deduplication across savepoints" do
  before_all do
    CommitDedupSavepointModel.migrator.drop_and_create
  end

  before_each do
    CommitDedupSavepointModel.clear
    CommitDedupSavepointModel.event_log.clear
  end

  it "does not fire commit callbacks for an update undone by a rolled back savepoint" do
    CommitDedupSavepointModel.transaction do
      record = CommitDedupSavepointModel.create(name: "a")
      CommitDedupSavepointModel.transaction(requires_new: true) do
        record.name = "b"
        record.save
        raise Grant::Transaction::Rollback.new
      end
    end

    CommitDedupSavepointModel.event_log.should_not contain("update_commit")
    CommitDedupSavepointModel.event_log.should_not contain("commit_on_update")
    CommitDedupSavepointModel.event_log.count("create_commit").should eq(1)
    CommitDedupSavepointModel.event_log.count("commit").should eq(1)
  end

  it "runs after_rollback for the savepoint work and commit callbacks for the rest" do
    CommitDedupSavepointModel.transaction do
      record = CommitDedupSavepointModel.create(name: "a")
      CommitDedupSavepointModel.transaction(requires_new: true) do
        record.name = "b"
        record.save
        raise Grant::Transaction::Rollback.new
      end
      CommitDedupSavepointModel.event_log.should eq(["rollback"])
    end

    CommitDedupSavepointModel.event_log.should eq(["rollback", "create_commit", "commit"])
  end

  it "runs after_rollback once per record when the whole transaction rolls back" do
    CommitDedupSavepointModel.transaction do
      record = CommitDedupSavepointModel.create(name: "a")
      record.name = "b"
      record.save
      raise Grant::Transaction::Rollback.new
    end

    CommitDedupSavepointModel.event_log.should eq(["rollback"])
  end

  it "filters after_rollback on: :destroy for a rolled back destroy" do
    record = CommitDedupSavepointModel.create(name: "a")
    CommitDedupSavepointModel.event_log.clear
    CommitDedupSavepointModel.transaction do
      record.destroy
      raise Grant::Transaction::Rollback.new
    end

    CommitDedupSavepointModel.event_log.should eq(["rollback_on_destroy", "rollback"])
  end
end

describe "commit callback operation resolution" do
  before_all do
    CommitDedupSavepointModel.migrator.drop_and_create
  end

  before_each do
    CommitDedupSavepointModel.clear
    CommitDedupSavepointModel.event_log.clear
  end

  it "resolves a record created then destroyed in one transaction to a destroy" do
    CommitDedupSavepointModel.transaction do
      record = CommitDedupSavepointModel.create(name: "a")
      record.destroy
    end

    CommitDedupSavepointModel.event_log.should eq(["commit"])
  end

  it "resolves a record updated then destroyed in one transaction to a destroy" do
    record = CommitDedupSavepointModel.create(name: "a")
    CommitDedupSavepointModel.event_log.clear
    CommitDedupSavepointModel.transaction do
      record.name = "b"
      record.save
      record.destroy
    end

    CommitDedupSavepointModel.event_log.should eq(["commit"])
  end

  it "resolves a rolled back update then destroy to a destroy for after_rollback on:" do
    record = CommitDedupSavepointModel.create(name: "a")
    CommitDedupSavepointModel.event_log.clear
    CommitDedupSavepointModel.transaction do
      record.name = "b"
      record.save
      record.destroy
      raise Grant::Transaction::Rollback.new
    end

    CommitDedupSavepointModel.event_log.should eq(["rollback_on_destroy", "rollback"])
  end
end
