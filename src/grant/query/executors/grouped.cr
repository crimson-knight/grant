module Grant::Query::Executor
  class Grouped(Model)
    include Shared

    def initialize(@sql : String, @group_count : Int32, @args = [] of Grant::Columns::Type)
    end

    def run : Hash(Array(Grant::Columns::Type), Int64)
      log @sql, @args

      adapter = Model.adapter
      Grant::QueryCache.fetch(adapter, @sql, @args, Model.name, ->(cached : Hash(Array(Grant::Columns::Type), Int64)) { cached.dup }) do
        results = {} of Array(Grant::Columns::Type) => Int64
        adapter.open(@sql, @args, Model.name) do |db|
          db.query @sql, args: adapter.normalize_bind_values(@args) do |rows|
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
end
