# :nodoc:
module Grant::Query::KeyListPredicate
  # Builds `field IN (...)` for non-nil keys. Nil is represented with an
  # `IS NULL` branch; an empty list matches no rows.
  def self.build(field_sql : String, keys : Array(Grant::Columns::Type)) : Tuple(String, Array(Grant::Columns::Type))
    present = keys.reject(&.nil?) # ameba:disable Style/IsAFilter (reject(Nil) would narrow the element type)
    has_nil = present.size != keys.size
    return {has_nil ? "#{field_sql} IS NULL" : "1=0", [] of Grant::Columns::Type} if present.empty?

    placeholders = Array.new(present.size, "?").join(", ")
    predicate = present.size == 1 ? "#{field_sql} = ?" : "#{field_sql} IN (#{placeholders})"
    predicate = "(#{predicate} OR #{field_sql} IS NULL)" if has_nil
    {predicate, present}
  end
end
