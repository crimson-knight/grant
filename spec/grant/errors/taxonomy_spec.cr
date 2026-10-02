require "../../spec_helper"

describe "Grant error taxonomy" do
  before_each do
    Parent.clear
    CallbackWithAbort.clear
  end

  describe "hierarchy" do
    it "roots every Grant error in Grant::ErrorBase" do
      [
        Grant::RecordNotSaved, Grant::RecordInvalid, Grant::RecordNotFound,
        Grant::Querying::NotFound, Grant::RecordNotDestroyed, Grant::StatementInvalid,
        Grant::RecordNotUnique, Grant::InvalidForeignKey, Grant::NotNullViolation,
        Grant::ValueTooLong, Grant::Deadlocked, Grant::SerializationFailure,
        Grant::LockWaitTimeout, Grant::StatementTimeout, Grant::QueryCanceled,
        Grant::NoDatabaseError, Grant::ConnectionNotEstablished,
        Grant::ConnectionTimeoutError, Grant::ConnectionFailed,
        Grant::AdapterNotAvailableError, Grant::Transaction::ReadOnlyError,
        Grant::ReadOnlyRecordError, Grant::Querying::NotUnique,
        Grant::Locking::Optimistic::StaleObjectError, Grant::STI::SubclassNotFound,
        Grant::STI::ImmutableTypeError, Grant::STI::TypeCastingError,
        Grant::ValueObjects::ValueObjectError, Grant::UnsupportedIndexHintError,
        Grant::Encryption::KeyProvider::KeyError, Grant::Encryption::Cipher::EncryptionError,
        Grant::Encryption::Cipher::DecryptionError, Grant::Async::AsyncError,
      ].each do |error_class|
        (error_class <= Grant::ErrorBase).should be_true
      end
    end

    it "nests the record errors" do
      (Grant::RecordInvalid < Grant::RecordNotSaved).should be_true
      (Grant::Querying::NotFound < Grant::RecordNotFound).should be_true
    end

    it "nests the statement errors under StatementInvalid" do
      [
        Grant::RecordNotUnique, Grant::InvalidForeignKey, Grant::NotNullViolation,
        Grant::ValueTooLong, Grant::TransactionRollbackError, Grant::LockWaitTimeout,
        Grant::StatementTimeout, Grant::QueryCanceled, Grant::NoDatabaseError,
      ].each do |error_class|
        (error_class < Grant::StatementInvalid).should be_true
      end
      (Grant::Deadlocked < Grant::TransactionRollbackError).should be_true
      (Grant::SerializationFailure < Grant::TransactionRollbackError).should be_true
    end

    it "nests the connection errors under ConnectionNotEstablished" do
      (Grant::ConnectionTimeoutError < Grant::ConnectionNotEstablished).should be_true
      (Grant::ConnectionFailed < Grant::ConnectionNotEstablished).should be_true
      (Grant::AdapterNotAvailableError < Grant::ConnectionNotEstablished).should be_true
    end

    it "keeps the historical names as the same classes" do
      Grant::Locking::DeadlockError.should eq(Grant::Deadlocked)
      Grant::Locking::LockWaitTimeoutError.should eq(Grant::LockWaitTimeout)
      Grant::Transaction::SerializationError.should eq(Grant::SerializationFailure)
      Grant::ReadOnlyError.should eq(Grant::Transaction::ReadOnlyError)
      Grant::ConnectionNotDefined.should eq(Grant::AdapterNotAvailableError)
    end

    it "lets one rescue clause catch any Grant error" do
      raised = begin
        Parent.find!(0)
      rescue ex : Grant::ErrorBase
        ex
      end
      raised.should be_a(Grant::Querying::NotFound)
      raised.should be_a(Grant::RecordNotFound)
    end
  end

  describe "RecordInvalid" do
    it "is raised by save! with the record and every full message" do
      parent = Parent.new
      error = expect_raises(Grant::RecordInvalid) { parent.save! }

      error.record.should be(parent)
      error.model.should be(parent)
      error.record.errors.full_messages.should eq(["Name Name cannot be blank"])
      error.message.should eq("Validation failed: Name Name cannot be blank")
    end

    it "joins several failures into one message" do
      parent = Parent.new
      parent.errors.add(:name, "is too short")
      parent.errors.add(:base, "Record is invalid")

      Grant::RecordInvalid.new(parent).message.should eq(
        "Validation failed: Name is too short, Record is invalid")
    end

    it "is raised by create!" do
      error = expect_raises(Grant::RecordInvalid, "Validation failed: Name Name cannot be blank") do
        Parent.create!(name: "")
      end
      error.record.should be_a(Parent)
      Parent.count.should eq(0)
    end

    it "is raised by update!" do
      parent = Parent.create!(name: "Ada")
      expect_raises(Grant::RecordInvalid, "Validation failed: Name Name cannot be blank") do
        parent.update!(name: "")
      end
      Parent.find!(parent.id).name.should eq("Ada")
    end

    it "can still be rescued as RecordNotSaved" do
      expect_raises(Grant::RecordNotSaved) { Parent.new.save! }
    end

    it "does not fail when no errors were recorded" do
      Grant::RecordInvalid.new(Parent.new).message.should eq("Validation failed")
    end
  end

  describe "RecordNotSaved" do
    it "is raised, not RecordInvalid, when a callback aborts the save" do
      record = CallbackWithAbort.new(abort_at: "before_save", do_abort: true)
      record.history = IO::Memory.new

      error = expect_raises(Grant::RecordNotSaved) { record.save! }
      error.should_not be_a(Grant::RecordInvalid)
      error.model.should be(record)
    end

    it "builds a safe message when a callback halted the save without an error" do
      halted = Parent.new
      halted.errors.empty?.should be_true

      message = Grant::RecordNotSaved.new("Parent", halted).message
      message.should eq("Could not process Parent: the save was halted before the record was persisted")
    end

    it "keeps the existing message when an error was recorded" do
      parent = Parent.new
      parent.save
      Grant::RecordNotSaved.new("Parent", parent).message.should eq("Could not process Parent: Name cannot be blank")
    end
  end
end
