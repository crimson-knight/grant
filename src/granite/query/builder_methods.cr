module Granite::Query::BuilderMethods
  def __builder
    db_type = case adapter.class.to_s
              when "Granite::Adapter::Pg"
                Granite::Query::Builder::DbType::Pg
              when "Granite::Adapter::Mysql"
                Granite::Query::Builder::DbType::Mysql
              else
                Granite::Query::Builder::DbType::Sqlite
              end

    Builder(self).new(db_type)
  end

  delegate where, order, offset, limit, lock, to: __builder
  delegate pluck, pick, in_batches, annotate, to: __builder
end
