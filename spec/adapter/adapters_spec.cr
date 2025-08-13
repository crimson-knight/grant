require "../spec_helper"

class Foo < Grant::Base
  connection {{env("CURRENT_ADAPTER").id}}
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
        connection[:writer].url.should eq ADAPTER_URL
      else
        connection.should_not be_falsey
      end

      case ENV["CURRENT_ADAPTER"]?
      when "sqlite"
        if connection = Grant::Connections["sqlite_with_replica"]
          connection[:writer].url.should eq ENV["SQLITE_DATABASE_URL"]?
          connection[:reader].url.should eq ADAPTER_REPLICA_URL
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
      adapter.name.should eq CURRENT_ADAPTER
      adapter.url.should eq ADAPTER_URL
    end

    it "should use the first registered connection if none are specified" do
      adapter = Bar.adapter
      adapter.name.should eq CURRENT_ADAPTER
      adapter.url.should eq ADAPTER_URL
    end
  end
end
