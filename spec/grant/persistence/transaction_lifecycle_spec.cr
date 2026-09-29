require "./persistence_regression_helper"

describe "Grant transaction lifecycle regressions T6" do
  before_each do
    T6PersistenceRecord.clear
    T6HaltedRecord.clear
    T6CommitFailureRecord.clear
  end

  it "restores a created record to new state when its transaction rolls back" do
    record = T6PersistenceRecord.new(name: "rolled back")

    T6PersistenceRecord.transaction do
      record.save!.should be_true
      raise Grant::Transaction::Rollback.new
    end

    record.new_record?.should be_true
    record.persisted?.should be_false
    T6PersistenceRecord.count.should eq(0)

    record.save!.should be_true
    record.persisted?.should be_true
    T6PersistenceRecord.count.should eq(1)
  end

  it "restores updated record state after transaction rollback" do
    record = T6PersistenceRecord.create!(name: "before")

    T6PersistenceRecord.transaction do
      record.update!(name: "inside")
      raise Grant::Transaction::Rollback.new
    end

    record.name.should eq("before")
    record.name_changed?.should be_false
    T6PersistenceRecord.find!(record.id).name.should eq("before")
  end

  it "restores only savepoint changes and keeps earlier outer writes" do
    record = T6PersistenceRecord.create!(name: "before")

    T6PersistenceRecord.transaction do
      record.update!(name: "outer")

      T6PersistenceRecord.transaction(requires_new: true) do
        record.update!(name: "inner")
        raise Grant::Transaction::Rollback.new
      end

      record.name.should eq("outer")
      record.name_changed?.should be_false
    end

    T6PersistenceRecord.find!(record.id).name.should eq("outer")
  end

  it "raises RecordNotSaved when create is halted without validation errors" do
    expect_raises(Grant::RecordNotSaved) do
      T6HaltedRecord.create!(name: "must not persist")
    end

    T6HaltedRecord.count.should eq(0)
  end

  it "propagates after_commit exceptions after the row is committed" do
    error = expect_raises(Exception, "T6 after_commit failure") do
      T6CommitFailureRecord.transaction do
        T6CommitFailureRecord.create!(name: "durable")
      end
    end

    error.message.should eq("T6 after_commit failure")
    T6CommitFailureRecord.count.should eq(1)
    T6CommitFailureRecord.transaction_open?.should be_false
  end
end
