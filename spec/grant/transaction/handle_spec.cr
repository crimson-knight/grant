require "../../spec_helper"

describe Grant::Transaction::Handle do
  describe "with no open transaction" do
    it "is a closed null handle that runs after_commit immediately" do
      handle = Parent.current_transaction

      handle.open?.should be_false
      handle.closed?.should be_true
      handle.isolation.should be_nil

      ran = false
      handle.after_commit { ran = true }
      ran.should be_true

      rolled = false
      handle.after_rollback { rolled = true }
      rolled.should be_false
    end
  end

  describe "inside a transaction" do
    it "reports open? and isolation" do
      Parent.transaction(isolation: Grant::Transaction::IsolationLevel::ReadCommitted) do
        handle = Parent.current_transaction
        handle.open?.should be_true
        handle.isolation.should eq(Grant::Transaction::IsolationLevel::ReadCommitted)
        handle.readonly?.should be_false
      end
    end

    it "is the same handle in joined blocks and closed after the transaction" do
      captured : Grant::Transaction::Handle? = nil
      Parent.transaction do
        outer = Parent.current_transaction
        Parent.transaction { Parent.current_transaction.same?(outer).should be_true }
        captured = outer
      end

      captured.try(&.open?).should be_false
    end

    it "fires after_commit at COMMIT, not before, and drops after_rollback" do
      events = [] of Symbol
      Parent.transaction do
        Parent.current_transaction.after_commit { events << :commit }
        Parent.current_transaction.after_rollback { events << :rollback }
        events.should be_empty
      end

      events.should eq([:commit])
    end

    it "fires after_rollback on Rollback and drops after_commit" do
      events = [] of Symbol
      Parent.transaction do
        Parent.current_transaction.after_commit { events << :commit }
        Parent.current_transaction.after_rollback { events << :rollback }
        raise Grant::Transaction::Rollback.new
      end

      events.should eq([:rollback])
    end

    it "fires after_rollback when an exception escapes" do
      events = [] of Symbol
      expect_raises(Exception, "boom") do
        Parent.transaction do
          Parent.current_transaction.after_rollback { events << :rollback }
          raise "boom"
        end
      end

      events.should eq([:rollback])
    end

    it "runs callbacks in registration order" do
      order = [] of Int32
      Parent.transaction do
        handle = Parent.current_transaction
        handle.after_commit { order << 1 }
        handle.after_commit { order << 2 }
      end

      order.should eq([1, 2])
    end
  end

  describe "manual control" do
    it "commits a begun transaction" do
      Parent.clear
      connection = Parent.connection
      events = [] of Symbol

      handle = connection.begin_transaction
      handle.open?.should be_true
      handle.after_commit { events << :commit }
      Parent.create!(name: "Manual")
      handle.commit

      handle.open?.should be_false
      events.should eq([:commit])
      Parent.transaction_open?.should be_false
      Parent.count.should eq(1)
    end

    it "rolls back a begun transaction" do
      Parent.clear
      connection = Parent.connection
      events = [] of Symbol

      handle = connection.begin_transaction
      handle.after_rollback { events << :rollback }
      Parent.create!(name: "Manual")
      connection.rollback

      events.should eq([:rollback])
      Parent.transaction_open?.should be_false
      Parent.count.should eq(0)
    end

    it "opens nested manual handles as savepoints" do
      Parent.clear
      connection = Parent.connection

      outer = connection.begin_transaction
      Parent.create!(name: "Outer")
      inner = connection.begin_transaction
      inner.open?.should be_true
      Parent.create!(name: "Inner")
      inner.rollback
      inner.open?.should be_false
      outer.open?.should be_true
      outer.commit

      Parent.all.map(&.name).should eq(["Outer"])
    end

    it "raises NotOpenError when nothing is open or a handle is reused" do
      connection = Parent.connection
      expect_raises(Grant::Transaction::NotOpenError) { connection.commit }
      expect_raises(Grant::Transaction::NotOpenError) { connection.rollback }

      handle = connection.begin_transaction
      handle.commit
      expect_raises(Grant::Transaction::NotOpenError) { handle.commit }
    end

    it "runs named savepoint blocks and validates the name" do
      Parent.clear
      connection = Parent.connection

      Parent.transaction do
        Parent.create!(name: "Outer")
        connection.savepoint("before_extra") do
          Parent.create!(name: "Extra")
          raise Grant::Transaction::Rollback.new
        end
      end
      Parent.count.should eq(1)

      expect_raises(Grant::Transaction::NotOpenError) { connection.savepoint("x") { } }
      Parent.transaction do
        expect_raises(Grant::Transaction::InvalidSavepointNameError) { connection.savepoint("x; DROP TABLE parents") { } }
      end
    end
  end

  describe "model independent transactions" do
    it "shares the stack with Model.transaction" do
      Parent.clear

      Grant.transaction do
        Parent.transaction_open?.should be_true
        Parent.create!(name: "Via Grant")
        raise Grant::Transaction::Rollback.new
      end

      Parent.count.should eq(0)
    end

    it "accepts a database name and options" do
      Parent.clear
      Grant.transaction(CURRENT_ADAPTER, isolation: Grant::Transaction::IsolationLevel::ReadCommitted) do
        Parent.create!(name: "Named")
      end
      Parent.count.should eq(1)
    end

    it "runs raw connection SQL inside the transaction" do
      Parent.clear
      Grant.connection(CURRENT_ADAPTER).transaction do
        Grant.connection(CURRENT_ADAPTER).execute("INSERT INTO parents (name) VALUES ('raw')")
        raise Grant::Transaction::Rollback.new
      end
      Parent.count.should eq(0)
    end
  end
end
