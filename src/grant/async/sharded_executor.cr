require "./result"
require "./coordinator"

module Grant
  module Async
    # Executes async operations across multiple shards
    class ShardedExecutor
      # Execute an operation across multiple shards in parallel
      def self.execute_across_shards(shards : Array(Symbol), &block : Symbol -> AsyncResult(T)) : Hash(Symbol, AsyncResult(T)) forall T
        results = {} of Symbol => AsyncResult(T)
        
        shards.each do |shard|
          results[shard] = Grant::ShardManager.with_shard(shard) do
            block.call(shard)
          end
        end
        
        results
      end
      
      # Execute and wait for all results
      def self.execute_and_wait(shards : Array(Symbol), &block : Symbol -> AsyncResult(T)) : Hash(Symbol, T) forall T
        async_results = execute_across_shards(shards, &block)
        
        coordinator = Coordinator.new
        async_results.each_value { |result| coordinator.add(result) }
        coordinator.wait_all
        
        # Convert to actual values
        results = {} of Symbol => T
        async_results.each do |shard, async_result|
          results[shard] = async_result.wait
        end
        
        results
      end
      
      # Execute with aggregation
      def self.execute_and_aggregate(shards : Array(Symbol), &block : Symbol -> AsyncResult(T)) : T forall T
        results = execute_and_wait(shards, &block)
        
        # Aggregate based on type
        values = results.values
        first_value = values.first
        
        case first_value
        when Number
          # Sum for numbers
          values.sum
        when Array
          # Flatten for arrays
          values.flatten
        when Bool
          # Any true for booleans
          values.any?
        else
          # Return all values for other types
          values
        end.as(T)
      end
      
      # Map-reduce pattern
      def self.map_reduce(shards : Array(Symbol), 
                         map : Symbol -> AsyncResult(T),
                         reduce : Array(T) -> U) : U forall T, U
        results = execute_and_wait(shards) { |shard| map.call(shard) }
        reduce.call(results.values)
      end
      
      # Execute with timeout across all shards
      def self.execute_with_timeout(shards : Array(Symbol), 
                                   timeout : Time::Span,
                                   &block : Symbol -> AsyncResult(T)) : Hash(Symbol, T | Nil) forall T
        async_results = execute_across_shards(shards, &block)
        
        results = {} of Symbol => T | Nil
        
        async_results.each do |shard, async_result|
          begin
            results[shard] = async_result.wait_with_timeout(timeout)
          rescue AsyncTimeoutError
            results[shard] = nil
          end
        end
        
        results
      end
      
      # Execute with fallback
      def self.execute_with_fallback(primary_shard : Symbol,
                                    fallback_shards : Array(Symbol),
                                    &block : Symbol -> AsyncResult(T)) : T forall T
        begin
          Grant::ShardManager.with_shard(primary_shard) do
            block.call(primary_shard).wait
          end
        rescue e
          # Try fallback shards
          fallback_shards.each do |shard|
            begin
              return Grant::ShardManager.with_shard(shard) do
                block.call(shard).wait
              end
            rescue
              # Continue to next fallback
            end
          end
          
          # Re-raise original error if all fallbacks failed
          raise e
        end
      end
    end
  end
end