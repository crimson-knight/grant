require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SaveCommitModel < Grant::Base
    connection {{ adapter_literal }}
    table save_commit_models

    column id : Int64, primary: true
    column name : String?

    class_property event_log : Array(String) = [] of String

    after_save_commit { SaveCommitModel.event_log << "save_commit:#{name}" }
    after_commit { SaveCommitModel.event_log << "commit:#{name}" }
  end

  class SaveCommitBothModel < Grant::Base
    connection {{ adapter_literal }}
    table save_commit_both_models

    column id : Int64, primary: true
    column name : String?

    class_property event_log : Array(String) = [] of String

    after_create_commit { SaveCommitBothModel.event_log << "create_commit" }
    after_update_commit { SaveCommitBothModel.event_log << "update_commit" }
    after_save_commit { SaveCommitBothModel.event_log << "save_commit" }
  end
{% end %}

describe "after_save_commit" do
  before_all do
    SaveCommitModel.migrator.drop_and_create
    SaveCommitBothModel.migrator.drop_and_create
  end

  before_each do
    SaveCommitModel.clear
    SaveCommitBothModel.clear
    SaveCommitModel.event_log.clear
    SaveCommitBothModel.event_log.clear
  end

  it "fires once after a create and once after an update" do
    record = SaveCommitModel.create(name: "a")
    SaveCommitModel.event_log.should eq(["save_commit:a", "commit:a"])

    SaveCommitModel.event_log.clear
    record.name = "b"
    record.save
    SaveCommitModel.event_log.should eq(["save_commit:b", "commit:b"])
  end

  it "does not fire on destroy" do
    record = SaveCommitModel.create(name: "a")
    SaveCommitModel.event_log.clear
    record.destroy
    SaveCommitModel.event_log.should eq(["commit:a"])
  end

  it "fires once even with after_create_commit registered too" do
    record = SaveCommitBothModel.create(name: "a")
    SaveCommitBothModel.event_log.should eq(["create_commit", "save_commit"])

    SaveCommitBothModel.event_log.clear
    record.name = "b"
    record.save
    SaveCommitBothModel.event_log.should eq(["update_commit", "save_commit"])
  end

  it "waits for the outer commit and fires once for create then update" do
    SaveCommitBothModel.transaction do
      record = SaveCommitBothModel.create(name: "a")
      record.name = "b"
      record.save
      SaveCommitBothModel.event_log.should be_empty
    end
    # ActiveRecord resolves create-then-update to a create.
    SaveCommitBothModel.event_log.should eq(["create_commit", "save_commit"])
  end

  it "does not fire when the transaction rolls back" do
    SaveCommitBothModel.transaction do
      SaveCommitBothModel.create(name: "a")
      raise Grant::Transaction::Rollback.new
    end
    SaveCommitBothModel.event_log.should be_empty
  end
end
