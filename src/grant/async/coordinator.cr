require "wait_group"
require "./result"

module Grant
  module Async
    # Manages multiple async operations using WaitGroup
    class Coordinator
      @wait_group : WaitGroup
      @tracked_results : Array(TrackedResult)
      @errors : Array(Exception)
      @mutex : Mutex
      @result_count : Int32
      
      # Internal structure to track results without type constraints
      private struct TrackedResult
        property id : String
        property completed : Bool
        
        def initialize(@id : String)
          @completed = false
        end
      end
      
      def initialize
        @wait_group = WaitGroup.new
        @tracked_results = [] of TrackedResult
        @errors = [] of Exception
        @mutex = Mutex.new
        @result_count = 0
      end
      
      # Add an async result to track (returns an ID for retrieval)
      def add(result : Result(T)) : String forall T
        id = @mutex.synchronize do
          @result_count += 1
          result_id = "result_#{@result_count}"
          @tracked_results << TrackedResult.new(result_id)
          result_id
        end
        
        @wait_group.add(1)
        spawn do
          begin
            result.wait
            @mutex.synchronize do
              if tracked = @tracked_results.find { |tr| tr.id == id }
                tracked.completed = true
              end
            end
          rescue e
            @mutex.synchronize do
              @errors << e
            end
          ensure
            @wait_group.done
          end
        end
        
        id
      end
      
      # Add multiple results and return their IDs
      def add_all(results : Array(Result(T))) : Array(String) forall T
        results.map { |result| add(result) }
      end
      
      # Wait for all operations to complete
      def wait_all : Nil
        @wait_group.wait
        
        # Check for errors after all operations complete
        @mutex.synchronize do
          if @errors.any?
            failed_ops = @errors.map(&.message).compact
            raise AsyncCoordinationError.new(failed_ops)
          end
        end
      end
      
      # Wait with timeout
      def wait_all_with_timeout(timeout : Time::Span) : Bool
        channel = Channel(Bool).new
        
        spawn do
          wait_all
          channel.send(true)
        end
        
        select
        when channel.receive
          true
        when timeout(timeout)
          false
        end
      end
      
      # Get count of results
      def result_count : Int32
        @mutex.synchronize { @tracked_results.size }
      end
      
      # Get errors if any
      def errors : Array(Exception)
        @mutex.synchronize { @errors.dup }
      end
      
      # Check if any operations failed
      def any_failed? : Bool
        @mutex.synchronize { @errors.any? }
      end
      
      # Get count of tracked operations
      def size : Int32
        @mutex.synchronize { @tracked_results.size }
      end
      
      # Check if all operations completed successfully
      def all_completed? : Bool
        @mutex.synchronize do
          @errors.empty? && @tracked_results.all?(&.completed)
        end
      end
    end
    
    # Extended coordinator that stores actual results
    class ResultCoordinator(T)
      @coordinator : Coordinator
      @results : Hash(String, Result(T))
      @mutex : Mutex
      
      def initialize
        @coordinator = Coordinator.new
        @results = {} of String => Result(T)
        @mutex = Mutex.new
      end
      
      def add(result : Result(T)) : String
        id = @coordinator.add(result)
        @mutex.synchronize { @results[id] = result }
        id
      end
      
      def get(id : String) : Result(T)?
        @mutex.synchronize { @results[id]? }
      end
      
      def wait_all : Hash(String, T)
        @coordinator.wait_all
        
        values = {} of String => T
        @mutex.synchronize do
          @results.each do |id, result|
            values[id] = result.wait
          end
        end
        values
      end
      
      delegate :errors, :any_failed?, :size, to: @coordinator
    end
  end
end