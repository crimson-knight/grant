require "../../spec_helper"

{% begin %}
  {% adapter_literal = env("CURRENT_ADAPTER").id %}

  # Shares the parents table, but reads may route to a separate reader adapter
  # instance (same URL, its own pool), so any statement that escapes the
  # transaction runs on a different physical connection.
  class TransactionReplicaParent < Grant::Base
    connection {{ adapter_literal }}
    table parents

    column id : Int64, primary: true
    column name : String?
    timestamps
  end
{% end %}

TransactionReplicaParent.connection_config = {
  :writing => CURRENT_ADAPTER,
  :reading => "#{CURRENT_ADAPTER}_with_replica",
}

# Makes the read/write splitter pick the replica as soon as it can.
private def with_immediate_replica_reads(&) : Nil
  previous_wait_period = TransactionReplicaParent.connection_switch_wait_period
  TransactionReplicaParent.connection_switch_wait_period = 0
  begin
    yield
  ensure
    TransactionReplicaParent.connection_switch_wait_period = previous_wait_period
  end
end

describe "Transaction replica routing" do
  it "routes reads to the reader outside a transaction (control)" do
    with_immediate_replica_reads do
      writer = Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER, :writing)
      TransactionReplicaParent.adapter.same?(writer).should be_false
    end
  end

  it "keeps every statement inside the transaction on the writer" do
    Parent.clear

    with_immediate_replica_reads do
      writer = Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER, :writing)

      TransactionReplicaParent.transaction do
        TransactionReplicaParent.adapter.same?(writer).should be_true
        TransactionReplicaParent.create!(name: "In transaction")
        # The uncommitted row is visible only on the transaction connection.
        TransactionReplicaParent.where(name: "In transaction").count.should eq(1)
        raise Grant::Transaction::Rollback.new
      end
    end

    Parent.count.should eq(0)
  end

  it "keeps a readonly transaction's reads on the writer" do
    with_immediate_replica_reads do
      writer = Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER, :writing)

      TransactionReplicaParent.transaction(readonly: true) do
        TransactionReplicaParent.adapter.same?(writer).should be_true
      end
    end
  end
end
