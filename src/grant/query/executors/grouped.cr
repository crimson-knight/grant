module Grant::Query::Executor
  class Grouped(Model)
    include Shared

    def initialize(@sql : String, @group_count : Int32, @args = [] of Grant::Columns::Type)
    end

    def run : Hash(Array(Grant::Columns::Type), Int64)
      log @sql, @args
      results = {} of Array(Grant::Columns::Type) => Int64

      Model.adapter.open do |db|
        db.query @sql, args: @args do |rows|
          rows.each do
            key = [] of Grant::Columns::Type
            @group_count.times { key << rows.read(Grant::Columns::Type) }
            results[key] = rows.read(Int64)
          end
        end
      end

      results
    end
  end
end
