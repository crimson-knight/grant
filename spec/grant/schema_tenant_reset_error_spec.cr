require "../spec_helper"

{% if env("CURRENT_ADAPTER") == "pg" %}
  class SchemaTenantResetBlockFailure < Grant::ErrorBase
  end

  describe "Grant::SchemaTenant reset failures" do
    it "raises the reset error with its database cause when the block succeeds" do
      adapter = Grant::ConnectionRegistry.get_adapter("pg", :writing)

      reset_error = expect_raises(Grant::SchemaTenantResetError) do
        Grant::SchemaTenant.with("reset_probe", adapter: adapter) do
          terminate_schema_tenant_connection(adapter)
        end
      end

      reset_error.cause.should_not be_nil
      reset_error.block_exception.should be_nil
    end

    it "preserves the block error and attaches the reset failure" do
      adapter = Grant::ConnectionRegistry.get_adapter("pg", :writing)

      block_error = expect_raises(SchemaTenantResetBlockFailure) do
        Grant::SchemaTenant.with("reset_probe", adapter: adapter) do
          terminate_schema_tenant_connection(adapter)
          raise SchemaTenantResetBlockFailure.new("preserve this failure")
        end
      end

      reset_error = block_error.cleanup_error.should be_a(Grant::SchemaTenantResetError)
      reset_error.cause.should_not be_nil
      reset_error.block_exception.should be(block_error)
    end
  end

  private def terminate_schema_tenant_connection(adapter : Grant::Adapter::Base) : Nil
    if connection = Grant::SchemaTenant.current_connection?(adapter)
      process_id = connection.scalar("SELECT pg_backend_pid()").as(Int32)
      adapter.database.using_connection do |killer|
        killer.exec("SELECT pg_terminate_backend(#{process_id})")
      end
    end
  end
{% end %}
