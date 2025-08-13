module Grant
  module Adapter
    abstract class Base
      def name : String
        ""
      end
    end
    
    class Sqlite < Base
      def initialize(@name : String, @uri : String)
      end
    end
  end
  
  class ReplicaLoadBalancer
    @adapters : Array(Grant::Adapter::Base)
    
    def initialize(@adapters : Array(Grant::Adapter::Base))
    end
  end
end

adapters = [] of Grant::Adapter::Base
adapters << Grant::Adapter::Sqlite.new("test", "sqlite3::memory:")

balancer = Grant::ReplicaLoadBalancer.new(adapters)
puts "Success"
