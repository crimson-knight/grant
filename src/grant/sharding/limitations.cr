module Grant::Sharding
  # Document known limitations and provide helpful errors
  module Limitations
    class CrossShardJoinError < Exception
      def initialize(table1 : String, table2 : String)
        super("Cannot join #{table1} with #{table2} - they are on different shards. Consider denormalizing data or using application-level joins.")
      end
    end
    
    class DistributedTransactionError < Exception
      def initialize
        super("Distributed transactions across shards are not supported. Keep related updates on the same shard or use eventual consistency patterns.")
      end
    end
    
    # Detect cross-shard operations at compile time where possible
    macro validate_no_cross_shard_joins
      {% verbatim do %}
        # This would require AST analysis of the query
        # For now, we document the limitation
      {% end %}
    end
    
    # Best practices documentation
    module BestPractices
      RECOMMENDATIONS = {
        "Keep related data together" => [
          "Shard users and their orders by user_id",
          "Keep order and order_items on same shard",
          "Denormalize frequently joined data"
        ],
        
        "Avoid distributed transactions" => [
          "Use event sourcing for cross-shard updates",
          "Implement saga pattern for complex workflows",
          "Accept eventual consistency where possible"
        ],
        
        "Handle cross-shard queries in application" => [
          "Fetch from multiple shards in parallel",
          "Join data in application memory",
          "Use read replicas for analytics"
        ]
      }
      
      def self.print_warning(operation : String)
        puts "WARNING: #{operation} detected across shards"
        puts "See Grant::Sharding::Limitations::BestPractices for alternatives"
      end
    end
  end
  
  # Simple helper for application-level joins
  module ApplicationJoins
    # Fetch related records from different shards
    def self.fetch_related(base_records : Array(T), 
                          relation_class : U.class,
                          foreign_key : Symbol,
                          shard_key : Symbol) forall T, U
      # Group by shard
      by_shard = base_records.group_by do |record|
        value = record.read_attribute(foreign_key.to_s)
        U.sharding_config.try(&.resolver.resolve_for_keys(**{shard_key => value}))
      end
      
      # Fetch from each shard in parallel
      results = {} of String => Array(U)
      
      channel = Channel(Tuple(String, Array(U))).new
      
      by_shard.each do |shard, records|
        spawn do
          ids = records.map { |r| r.read_attribute(foreign_key.to_s) }
          ShardManager.with_shard(shard) do
            related = U.where(shard_key => ids).select
            channel.send({shard.to_s, related})
          end
        end
      end
      
      # Collect results
      by_shard.size.times do
        shard, related = channel.receive
        results[shard] = related
      end
      
      results.values.flatten
    end
  end
end