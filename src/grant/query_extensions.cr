# Query extensions for association options
class Grant::Query::Builder(Model)
  def update_all(assignments : String)
    sql = "UPDATE #{Model.table_name} SET #{assignments}"
    
    if where_clause = assembler.where
      sql += " #{where_clause}"
    end
    
    Model.adapter.open do |db|
      db.exec(sql)
    end
  end
end