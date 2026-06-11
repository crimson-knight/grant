require "../spec_helper"

describe "prevent_writes enforcement" do
  before_each do
    Todo.clear
  end

  describe "while_preventing_writes" do
    it "raises ReadOnlyError for Model.create!" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.create!(name: "blocked")
        end
      end
    end

    it "raises ReadOnlyError for Model.create" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.create(name: "blocked")
        end
      end
    end

    it "raises ReadOnlyError for instance save" do
      todo = Todo.new
      todo.name = "blocked"
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          todo.save
        end
      end
    end

    it "raises ReadOnlyError for instance save!" do
      todo = Todo.new
      todo.name = "blocked"
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          todo.save!
        end
      end
    end

    it "raises ReadOnlyError for instance destroy" do
      todo = Todo.create!(name: "to destroy")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          todo.destroy
        end
      end
    end

    it "raises ReadOnlyError for instance destroy!" do
      todo = Todo.create!(name: "to destroy bang")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          todo.destroy!
        end
      end
    end

    it "raises ReadOnlyError for instance touch" do
      todo = Todo.create!(name: "to touch")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          todo.touch
        end
      end
    end

    it "raises ReadOnlyError for Model.delete_all (bulk path)" do
      Todo.create!(name: "one")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.where(name: "one").delete_all
        end
      end
    end

    it "raises ReadOnlyError for import (bulk path)" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          todo = Todo.new
          todo.name = "imported"
          Todo.import([todo])
        end
      end
    end

    it "allows reads inside the block" do
      Todo.create!(name: "readable")
      Todo.while_preventing_writes do
        results = Todo.all
        results.size.should be >= 1
      end
    end

    it "allows writes again after the block exits" do
      Todo.while_preventing_writes do
        # block exits cleanly
      end
      todo = Todo.create!(name: "after block")
      todo.persisted?.should be_true
    end

    it "does not affect writes outside the block" do
      Todo.preventing_writes?.should be_false
      todo = Todo.create!(name: "outside")
      todo.persisted?.should be_true
    end
  end

  describe "connected_to(prevent_writes: true)" do
    it "raises ReadOnlyError for Model.create!" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.connected_to(prevent_writes: true) do
          Todo.create!(name: "connected_to blocked")
        end
      end
    end

    it "raises ReadOnlyError for instance save" do
      todo = Todo.new
      todo.name = "blocked"
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.connected_to(prevent_writes: true) do
          todo.save
        end
      end
    end

    it "raises ReadOnlyError for instance destroy" do
      todo = Todo.create!(name: "connected_to destroy")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.connected_to(prevent_writes: true) do
          todo.destroy
        end
      end
    end

    it "raises ReadOnlyError for delete_all bulk path" do
      Todo.create!(name: "bulk delete")
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.connected_to(prevent_writes: true) do
          Todo.where(name: "bulk delete").delete_all
        end
      end
    end

    it "allows reads inside connected_to prevent_writes block" do
      Todo.create!(name: "ct readable")
      Todo.connected_to(prevent_writes: true) do
        results = Todo.all
        results.size.should be >= 1
      end
    end

    it "allows writes after connected_to prevent_writes block exits" do
      Todo.connected_to(prevent_writes: true) do
        # nothing
      end
      todo = Todo.create!(name: "after connected_to")
      todo.persisted?.should be_true
    end
  end

  describe "remaining guarded write paths" do
    it "raises ReadOnlyError for Model.clear" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.clear
        end
      end
    end

    it "raises ReadOnlyError for Model.destroy_by" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.destroy_by(name: "nope")
        end
      end
    end

    it "raises ReadOnlyError for Model.delete_by" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.delete_by(name: "nope")
        end
      end
    end

    it "raises ReadOnlyError for Model.touch_all" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.touch_all
        end
      end
    end

    it "raises ReadOnlyError for Model.update_counters" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.update_counters(1, {:priority => 1})
        end
      end
    end

    it "raises ReadOnlyError for Model.exec" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.exec("UPDATE todos SET name = 'x'")
        end
      end
    end

    it "raises ReadOnlyError for Model.query" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.query("SELECT * FROM todos") { |_rs| }
        end
      end
    end

    it "raises ReadOnlyError for Model.insert_all" do
      attrs = [{"name" => "bulk".as(Grant::Columns::Type)} of String | Symbol => Grant::Columns::Type]
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.insert_all(attrs)
        end
      end
    end

    it "raises ReadOnlyError for Model.upsert_all" do
      attrs = [{"name" => "bulk".as(Grant::Columns::Type)} of String | Symbol => Grant::Columns::Type]
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.upsert_all(attrs)
        end
      end
    end

    it "raises ReadOnlyError for builder update_all" do
      expect_raises(Grant::Transaction::ReadOnlyError) do
        Todo.while_preventing_writes do
          Todo.where(name: "x").update_all("name = 'y'")
        end
      end
    end
  end

  describe "exception path" do
    it "restores writability when an exception escapes while_preventing_writes" do
      expect_raises(Exception, "boom") do
        Todo.while_preventing_writes do
          raise "boom"
        end
      end
      Todo.preventing_writes?.should be_false
      todo = Todo.create!(name: "after exception")
      todo.persisted?.should be_true
    end
  end

  describe "nested connected_to restores outer prevent_writes state" do
    it "outer prevent_writes: true is still active after inner connected_to exits" do
      Todo.connected_to(prevent_writes: true) do
        Todo.preventing_writes?.should be_true
        # inner connected_to inherits prevent_writes from outer context
        Todo.connected_to do
          Todo.preventing_writes?.should be_true
        end
        # outer state is still active after inner block exits
        Todo.preventing_writes?.should be_true
      end
      # fully restored after outer block
      Todo.preventing_writes?.should be_false
    end

    it "does not enable prevent_writes after inner prevent_writes block inside normal context" do
      Todo.preventing_writes?.should be_false
      Todo.connected_to do
        Todo.preventing_writes?.should be_false
        Todo.connected_to(prevent_writes: true) do
          Todo.preventing_writes?.should be_true
        end
        # outer normal context restored
        Todo.preventing_writes?.should be_false
      end
      Todo.preventing_writes?.should be_false
    end
  end
end
