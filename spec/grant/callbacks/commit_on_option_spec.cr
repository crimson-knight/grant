require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CommitOnModel < Grant::Base
    connection {{ adapter_literal }}
    table commit_on_models

    column id : Int64, primary: true
    column name : String?

    class_property event_log : Array(String) = [] of String

    after_commit(on: [:create, :update]) { CommitOnModel.event_log << "cu" }
    after_commit(on: :destroy) { CommitOnModel.event_log << "d" }
    after_commit { CommitOnModel.event_log << "any" }
    after_rollback(on: :create) { CommitOnModel.event_log << "rb_create" }
    after_rollback(on: [:update, :destroy]) { CommitOnModel.event_log << "rb_ud" }
    after_rollback { CommitOnModel.event_log << "rb_any" }
  end
{% end %}

describe "after_commit / after_rollback on:" do
  before_all do
    CommitOnModel.migrator.drop_and_create
  end

  before_each do
    CommitOnModel.clear
    CommitOnModel.event_log.clear
  end

  it "runs an on: array callback for create and update but not destroy" do
    record = CommitOnModel.create(name: "a")
    CommitOnModel.event_log.should eq(["cu", "any"])

    CommitOnModel.event_log.clear
    record.name = "b"
    record.save
    CommitOnModel.event_log.should eq(["cu", "any"])

    CommitOnModel.event_log.clear
    record.destroy
    CommitOnModel.event_log.should eq(["d", "any"])
  end

  it "filters after_rollback by the rolled back operation" do
    CommitOnModel.transaction do
      CommitOnModel.create(name: "a")
      raise Grant::Transaction::Rollback.new
    end
    CommitOnModel.event_log.should eq(["rb_create", "rb_any"])
  end

  it "keeps the update operation for a rolled back update" do
    record = CommitOnModel.create(name: "a")
    CommitOnModel.event_log.clear
    CommitOnModel.transaction do
      record.name = "b"
      record.save
      raise Grant::Transaction::Rollback.new
    end
    CommitOnModel.event_log.should eq(["rb_ud", "rb_any"])
  end

  it "runs commit callbacks once per record for repeated saves in one transaction" do
    CommitOnModel.transaction do
      record = CommitOnModel.create(name: "a")
      record.name = "b"
      record.save
      record.name = "c"
      record.save
      CommitOnModel.event_log.should be_empty
    end
    CommitOnModel.event_log.should eq(["cu", "any"])
  end

  it "matches on: :create for a record created then updated in one transaction" do
    CommitOnModel.transaction do
      record = CommitOnModel.create(name: "a")
      record.name = "b"
      record.save
    end
    CommitOnModel.event_log.count("cu").should eq(1)
  end

  it "dedupes per record, not per class" do
    CommitOnModel.transaction do
      CommitOnModel.create(name: "a")
      CommitOnModel.create(name: "b")
    end
    CommitOnModel.event_log.should eq(["cu", "any", "cu", "any"])
  end

  it "fires again for a later transaction" do
    record = CommitOnModel.create(name: "a")
    CommitOnModel.event_log.clear
    CommitOnModel.transaction do
      record.name = "b"
      record.save
    end
    CommitOnModel.event_log.should eq(["cu", "any"])
  end
end
