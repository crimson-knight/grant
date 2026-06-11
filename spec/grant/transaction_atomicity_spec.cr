require "../spec_helper"

# Spec for Bug 1: DML inside transaction block must use the transaction's connection,
# not a fresh pool connection — otherwise INSERTs are not inside the transaction.
describe "Grant::Transaction atomicity" do
  describe "rollback" do
    it "rolls back all records when an exception is raised inside the block" do
      Parent.clear

      expect_raises(Exception) do
        Parent.transaction do
          Parent.create!(name: "Alice")
          Parent.create!(name: "Bob")
          raise "force rollback"
        end
      end

      # Neither record should exist — both inserts were part of the transaction
      Parent.count.should eq(0)
    end

    it "rolls back all records when Grant::Transaction::Rollback is raised" do
      Parent.clear

      Parent.transaction do
        Parent.create!(name: "Charlie")
        Parent.create!(name: "Dave")
        raise Grant::Transaction::Rollback.new
      end

      Parent.count.should eq(0)
    end
  end

  describe "commit" do
    it "persists all records after a clean transaction block" do
      Parent.clear

      Parent.transaction do
        Parent.create!(name: "Eve")
        Parent.create!(name: "Frank")
      end

      Parent.count.should eq(2)
      names = Parent.all.map(&.name.to_s).sort
      names.should eq(["Eve", "Frank"])
    end
  end

  describe "cross-model" do
    it "rolls back records from different model classes inside one transaction" do
      Parent.clear
      Teacher.clear

      expect_raises(Exception) do
        Parent.transaction do
          Parent.create!(name: "CrossParent")
          Teacher.create!(name: "CrossTeacher")
          raise "cross rollback"
        end
      end

      Parent.count.should eq(0)
      Teacher.count.should eq(0)
    end
  end
end
