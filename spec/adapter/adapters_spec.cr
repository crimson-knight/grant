require "../spec_helper"

class Foo < Grant::Base
  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  column id : Int64, primary: true
end

class Bar < Grant::Base
  column id : Int64, primary: true
end

describe Grant::Connections do
  describe "registration" do
    it "should allow connections to be be saved and looked up" do
      Grant::Connections.registered_connections.size.should eq 2

      if connection = Grant::Connections[CURRENT_ADAPTER]
        expect_pooled_url(connection[:writer].url, ADAPTER_URL)
      else
        connection.should_not be_falsey
      end

      case CURRENT_ADAPTER
      when "sqlite"
        if connection = Grant::Connections["sqlite_with_replica"]
          expect_pooled_url(connection[:writer].url, ADAPTER_URL)
          expect_pooled_url(connection[:reader].url, ADAPTER_REPLICA_URL)
        else
          connection.should_not be_falsey
        end
      end
    end

    it "should disallow multiple connections with the same name" do
      Grant::Connections << Grant::Adapter::Pg.new(name: "mysql2", url: "mysql://localhost:3306/test")
      expect_raises(Exception, "Adapter with name 'mysql2' has already been registered.") do
        Grant::Connections << Grant::Adapter::Pg.new(name: "mysql2", url: "mysql://localhost:3306/test")
      end
    end

    it "should assign the correct connections to a model" do
      adapter = Foo.adapter
      adapter.name.should eq "#{CURRENT_ADAPTER}:primary"
      expect_pooled_url(adapter.url, ADAPTER_URL)
    end

    it "should use the first registered connection if none are specified" do
      adapter = Bar.adapter
      adapter.name.should eq "#{CURRENT_ADAPTER}:primary"
      expect_pooled_url(adapter.url, ADAPTER_URL)
    end
  end
end

private def expect_pooled_url(actual_url : String, source_url : String)
  actual_url.should start_with(source_url)

  pool_options = URI.parse(actual_url).query_params
  pool_options["max_pool_size"].should eq("25")
  pool_options["initial_pool_size"].should eq("2")
  pool_options["checkout_timeout"].should eq("5.0")
  pool_options["retry_attempts"].should eq("1")
  pool_options["retry_delay"].should eq("0.2")
end
