# Query extensions for association options
class Granite::Query::Builder(Model)
  def update_all(assignments : String)
    assembler = assembler_class.new(self)
    sql = "UPDATE #{@model_class.quoted_table_name} SET #{assignments}"
    
    if where_clause = assembler.where
      sql += " WHERE #{where_clause}"
    end
    
    @model_class.adapter.open do |db|
      db.exec(sql)
    end
  end
  
  def exists? : Bool
    limit(1).count > 0
  end
end