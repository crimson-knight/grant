module Granite::Query::Executor
  class Pluck(Model)
    include Shared

    def initialize(@sql : String, @args = [] of Granite::Columns::Type, @fields : Array(String) = [] of String)
    end

    def run : Array(Array(Granite::Columns::Type))
      log @sql, @args

      results = [] of Array(Granite::Columns::Type)

      Model.adapter.open do |db|
        db.query @sql, args: @args do |rs|
          rs.each do
            row = [] of Granite::Columns::Type
            @fields.each do |field|
              # Read values in order - rs.read advances to next column automatically
              row << rs.read(Granite::Columns::Type)
            end
            results << row
          end
        end
      end

      results
    end
  end
end