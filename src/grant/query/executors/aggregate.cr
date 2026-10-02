module Grant::Query::Executor
  alias AggregateRow = Tuple(Array(Grant::Columns::Type), Grant::Columns::Type)

  # Runs an aggregate query that returns the group key columns (none for an
  # ungrouped aggregate) followed by one aggregate value, and returns one
  # `{key, value}` pair per row. A grouped aggregate is one GROUP BY statement,
  # never a query per key.
  class Aggregate(Model)
    include Shared

    def initialize(@sql : String, @args : Array(Grant::Columns::Type), @group_count : Int32)
    end

    def run : Array(AggregateRow)
      log @sql, @args

      start_time = Time.instant
      rows = [] of AggregateRow

      begin
        adapter = Model.adapter
        adapter.open(@sql, @args, Model.name) do |db|
          db.query @sql, args: adapter.normalize_bind_values(@args) do |rs|
            rs.each do
              key = Array(Grant::Columns::Type).new(@group_count)
              @group_count.times { key << rs.read(Grant::Columns::Type) }
              rows << {key, rs.read(Grant::Columns::Type)}
            end
          end
        end

        log_query_with_timing(@sql, @args, Time.instant - start_time, rows.size, Model.name)
      rescue e
        Grant::Logs::SQL.error { "Aggregate query failed (#{(Time.instant - start_time).total_milliseconds}ms) - #{@sql} [#{Model.name}] - #{e.message}" }
        raise e
      end

      rows
    end
  end
end
