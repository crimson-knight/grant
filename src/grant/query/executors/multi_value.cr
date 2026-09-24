module Grant::Query::Executor
  class MultiValue(Model, Scalar)
    include Shared

    def initialize(@sql : String, @args = [] of Grant::Columns::Type, @default : Scalar = nil)
    end

    def run : Array(Scalar)
      log @sql, @args

      raise "No default provided" if @default.nil?
      results = [] of Scalar

      adapter = Model.adapter
      adapter.open do |db|
        db.query @sql, args: adapter.normalize_bind_values(@args) do |record_set|
          record_set.each do
            results << record_set.read(Scalar)
          end
        end
      end

      results
    end

    delegate :to_i, :to_s, to: :run
    delegate :<, :>, :<=, :>=, to: :run
  end
end
