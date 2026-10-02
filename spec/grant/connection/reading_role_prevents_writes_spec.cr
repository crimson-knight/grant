require "../../spec_helper"

describe "connected_to(role: :reading) prevents writes" do
  before_each do
    Todo.clear
  end

  it "raises ReadOnlyError for create! inside a reading block" do
    expect_raises(Grant::Transaction::ReadOnlyError) do
      Todo.connected_to(role: :reading) { Todo.create!(name: "blocked") }
    end
    Todo.count.should eq 0
  end

  it "raises for save, update, and destroy on existing records" do
    todo = Todo.create!(name: "existing")

    Todo.connected_to(role: :reading) do
      expect_raises(Grant::Transaction::ReadOnlyError) { todo.save }
      expect_raises(Grant::Transaction::ReadOnlyError) { todo.destroy }
      expect_raises(Grant::Transaction::ReadOnlyError) { Todo.where(name: "existing").delete_all }
    end
    Todo.count.should eq 1
  end

  it "still reads inside the reading block" do
    Todo.create!(name: "readable")

    Todo.connected_to(role: :reading) { Todo.count }.should eq 1
    Todo.connected_to(role: :reading) { Todo.first!.name }.should eq "readable"
  end

  it "allows writes again after the block, even when it raised" do
    expect_raises(Grant::Transaction::ReadOnlyError) do
      Todo.connected_to(role: :reading) { Todo.create!(name: "blocked") }
    end

    Todo.preventing_writes?.should be_false
    Todo.create!(name: "allowed").persisted?.should be_true
  end

  it "keeps prevention for nested blocks that leave the role unchanged" do
    Todo.connected_to(role: :reading) do
      Todo.connected_to(shard: :nested) do
        Todo.preventing_writes?.should be_true
        expect_raises(Grant::Transaction::ReadOnlyError) { Todo.create!(name: "blocked") }
      end
    end
  end

  it "lets an explicit writing role inside a reading block write" do
    Todo.connected_to(role: :reading) do
      Todo.connected_to(role: :writing) do
        Todo.preventing_writes?.should be_false
        Todo.create!(name: "from the writer")
      end
      Todo.preventing_writes?.should be_true
    end
    Todo.count.should eq 1
  end

  it "does not lift an explicit while_preventing_writes when the role is written" do
    Todo.while_preventing_writes do
      Todo.connected_to(role: :writing) do
        expect_raises(Grant::Transaction::ReadOnlyError) { Todo.create!(name: "blocked") }
      end
    end
  end

  it "treats :primary as an alias of :writing" do
    Todo.connected_to(role: :primary) { Todo.create!(name: "primary") }
    Todo.connected_to(role: :writing) { Todo.create!(name: "writing") }
    Todo.count.should eq 2

    Todo.connected_to(role: :reading) do
      Todo.connected_to(role: :primary) { Todo.create!(name: "primary again") }
    end
    Todo.count.should eq 3

    Todo.connected_to(role: :primary) { Todo.connected_to?(role: :writing) }.should be_true
  end

  it "reads the reading and writing role names from settings" do
    settings = Grant.settings
    settings.reading_role.should eq :reading
    settings.writing_role.should eq :writing
    Grant.reading_role.should eq :reading
    Grant.writing_role.should eq :writing

    begin
      settings.reading_role = :replica
      Todo.connected_to(role: :replica) do
        expect_raises(Grant::Transaction::ReadOnlyError) { Todo.create!(name: "blocked") }
      end
      # :reading is an ordinary role name once renamed
      Todo.connected_to(role: :reading) { Todo.create!(name: "not prevented") }
    ensure
      settings.reading_role = :reading
    end
  end

  it "rejects identical reading and writing roles" do
    expect_raises(ArgumentError) { Grant.settings.reading_role = :writing }
    expect_raises(ArgumentError) { Grant.settings.writing_role = :reading }
  end
end
