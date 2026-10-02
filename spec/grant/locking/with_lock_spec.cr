require "../../spec_helper"
require "../../../src/grant/spec_support/*"
require "../transaction/sql_recorder"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}
class WithLockSpecAccount < Grant::Base
  connection {{adapter_literal}}
  table with_lock_spec_accounts

  column id : Int64, primary: true
  column owner : String
  column balance : Int32 = 0
end
{% end %}

WithLockSpecAccount.migrator.drop_and_create

describe "with_lock" do
  before_each { WithLockSpecAccount.clear }

  describe "the block's value" do
    it "returns a non-nil value with its type" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 10)

      balance = account.with_lock { |locked| locked.balance }
      balance.should eq(10)
      typeof(balance).should eq(Int32)
    end

    it "returns nil when the block's value is nil" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 10)

      value = account.with_lock do |locked|
        locked.update!(balance: 11)
        nil
      end

      value.should be_nil
      typeof(value).should eq(Nil)
      WithLockSpecAccount.find!(account.id).balance.should eq(11)
    end

    it "returns a falsy value without treating it as missing" do
      account = WithLockSpecAccount.create!(owner: "Ada")
      account.with_lock { |_locked| false }.should be_false
    end

    it "gives the class-level forms the same generic return" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 3)

      WithLockSpecAccount.with_lock(account.id) { |locked| locked.owner }.should eq("Ada")
      WithLockSpecAccount.with_lock(account.id) { |_locked| nil }.should be_nil
      WithLockSpecAccount.with_lock { |locked| locked.balance }.should eq(3)
    end
  end

  describe "the locked reload" do
    it "yields the current row, not the stale in-memory copy" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 10)
      WithLockSpecAccount.where(id: account.id).update_all(balance: 99)

      account.balance.should eq(10)
      seen = account.with_lock { |locked| locked.balance }

      seen.should eq(99)
      account.balance.should eq(99)
      account.changed?.should be_false
    end

    it "yields the receiver itself" do
      account = WithLockSpecAccount.create!(owner: "Ada")
      account.with_lock { |locked| locked.same?(account) }.should be_true
    end

    it "takes the lock with one SELECT round trip" do
      account = WithLockSpecAccount.create!(owner: "Ada")

      queries = Grant::Spec.capture_queries do
        account.with_lock { |locked| locked.balance }
      end

      selects = queries.select(&.sql.starts_with?("SELECT"))
      selects.size.should eq(1)
      if WithLockSpecAccount.adapter.supports_lock_mode?(Grant::Locking::LockMode::Update)
        selects.first.sql.should contain("FOR UPDATE")
      end
    end

    it "commits the block's writes and rolls them back on an exception" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 1)

      account.with_lock { |locked| locked.update!(balance: 2) }
      WithLockSpecAccount.find!(account.id).balance.should eq(2)

      expect_raises(Exception, "boom") do
        account.with_lock do |locked|
          locked.update!(balance: 3)
          raise "boom"
        end
      end
      WithLockSpecAccount.find!(account.id).balance.should eq(2)
    end

    it "raises RecordNotFound for a row that is gone" do
      account = WithLockSpecAccount.create!(owner: "Ada")
      WithLockSpecAccount.where(id: account.id).delete_all

      expect_raises(Grant::Querying::NotFound) do
        account.with_lock { |_locked| 1 }
      end
    end
  end

  describe "requires_new" do
    it "joins the open transaction by default" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 1)

      statements = TransactionSqlRecorder.record do
        WithLockSpecAccount.transaction do
          account.with_lock { |locked| locked.balance }
        end
      end

      TransactionSqlRecorder.begins(statements).size.should eq(1)
      statements.none?(&.starts_with?("SAVEPOINT")).should be_true
    end

    it "opens a savepoint inside an open transaction" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 1)

      statements = TransactionSqlRecorder.record do
        WithLockSpecAccount.transaction do
          account.with_lock(requires_new: true) { |locked| locked.balance }
        end
      end

      TransactionSqlRecorder.begins(statements).size.should eq(1)
      statements.any?(&.starts_with?("SAVEPOINT")).should be_true
    end

    it "undoes only the inner work when the savepoint block fails" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 1)

      WithLockSpecAccount.transaction do
        WithLockSpecAccount.create!(owner: "Outer", balance: 5)
        begin
          account.with_lock(requires_new: true) do |locked|
            locked.update!(balance: 100)
            raise "inner failure"
          end
        rescue ex
          ex.message.should eq("inner failure")
        end
      end

      WithLockSpecAccount.find!(account.id).balance.should eq(1)
      WithLockSpecAccount.where(owner: "Outer").count.should eq(1)
    end
  end

  describe "isolation" do
    it "opens the outermost transaction at the requested level" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 1)

      statements = TransactionSqlRecorder.record do
        account.with_lock(isolation: Grant::Transaction::IsolationLevel::Serializable) do |locked|
          locked.balance
        end
      end

      begin_statement = TransactionSqlRecorder.begins(statements).first
      if WithLockSpecAccount.adapter.postgres?
        begin_statement.should contain("ISOLATION LEVEL SERIALIZABLE")
      elsif WithLockSpecAccount.adapter.sqlite?
        begin_statement.should eq("BEGIN EXCLUSIVE")
      else
        statements.any?(&.includes?("ISOLATION LEVEL SERIALIZABLE")).should be_true
      end
    end

    it "refuses an isolation level inside a transaction that is already open" do
      account = WithLockSpecAccount.create!(owner: "Ada")

      expect_raises(Grant::TransactionIsolationError) do
        WithLockSpecAccount.transaction do
          account.with_lock(isolation: Grant::Transaction::IsolationLevel::Serializable) { |_locked| 1 }
        end
      end
    end

    it "takes the isolation level on the class-level forms too" do
      account = WithLockSpecAccount.create!(owner: "Ada")

      expect_raises(Grant::TransactionIsolationError) do
        WithLockSpecAccount.transaction do
          WithLockSpecAccount.with_lock(account.id, isolation: Grant::Transaction::IsolationLevel::ReadCommitted) { |_locked| 1 }
        end
      end
    end
  end

  describe "a Rollback raised by the block" do
    it "undoes the work and raises Rollback again, since there is no value to return" do
      account = WithLockSpecAccount.create!(owner: "Ada", balance: 1)

      expect_raises(Grant::Transaction::Rollback) do
        account.with_lock do |locked|
          locked.update!(balance: 50)
          raise Grant::Transaction::Rollback.new
        end
      end

      WithLockSpecAccount.find!(account.id).balance.should eq(1)
    end
  end

  describe "row locks outside a transaction" do
    it "are refused by lock! where the adapter takes real locks, so the lock is never silently dropped" do
      account = WithLockSpecAccount.create!(owner: "Ada")

      if WithLockSpecAccount.adapter.supports_lock_mode?(Grant::Locking::LockMode::Update)
        expect_raises(Grant::Locking::TransactionRequiredError) { account.lock! }
      else
        account.lock!.should eq(account)
      end
    end

    it "are allowed inside a transaction" do
      account = WithLockSpecAccount.create!(owner: "Ada")
      WithLockSpecAccount.transaction { account.lock!.same?(account) }.should be_true
    end
  end
end
