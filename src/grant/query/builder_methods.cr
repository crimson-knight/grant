module Grant::Query::BuilderMethods
  def __builder
    db_type = case adapter.class.to_s
              when "Grant::Adapter::Pg"
                Grant::Query::Builder::DbType::Pg
              when "Grant::Adapter::Mysql"
                Grant::Query::Builder::DbType::Mysql
              else
                Grant::Query::Builder::DbType::Sqlite
              end

    Builder(self).new(db_type)
  end

  delegate where, order, offset, limit, lock, group_by, to: __builder
  delegate joins, left_joins, distinct, having, none, to: __builder
  delegate reorder, reverse_order, rewhere, reselect, regroup, to: __builder
  delegate pluck, pick, in_batches, annotate, to: __builder
  delegate includes, preload, eager_load, to: __builder
end
