module Grant::Query::AssociationConditionPlanner
  alias KeyEntry = Tuple(Grant::Columns::Type, String?)
  alias RawColumn = Tuple(String, String, Bool)
  alias FieldSQL = Proc(String, String)

  struct Plan
    getter where_fields : Array(Grant::Query::WhereField)
    getter raw_columns : Array(RawColumn)

    def initialize(@where_fields : Array(Grant::Query::WhereField), @raw_columns : Array(RawColumn))
    end
  end

  # Resolves an association value into the WHERE clauses and raw-column
  # bookkeeping the Builder applies to its typed relation.
  def self.build(join : Symbol, name : String, model_name : String,
                 reflection : Grant::Reflection, value : T,
                 field_sql : FieldSQL) : Plan forall T
    entries = key_entries(value)
    foreign_key = reflection.foreign_key
    where_fields = [] of Grant::Query::WhereField
    raw_columns = [] of RawColumn

    if entries.empty?
      where_fields << {join: join, stmt: "1=0", value: nil.as(Grant::Columns::Type)}
      return Plan.new(where_fields, raw_columns)
    end

    unless reflection.polymorphic?
      if entries.size == 1
        where_fields << {join: join, field: foreign_key, operator: :eq, value: entries.first[0]}
      else
        keys = entries.map(&.[0])
        predicate, values = Grant::Query::KeyListPredicate.build(field_sql.call(foreign_key), keys)
        where_fields << {join: join, stmt: predicate, values: values}
        raw_columns << {predicate, foreign_key, keys.none?(Nil)}
      end
      return Plan.new(where_fields, raw_columns)
    end

    type_column = reflection.foreign_type || raise ArgumentError.new("Polymorphic association #{model_name}##{name} has no type column")
    if join == :and && entries.size == 1 && (type_name = entries.first[1]) && !entries.first[0].nil?
      where_fields << {join: :and, field: foreign_key, operator: :eq, value: entries.first[0]}
      where_fields << {join: :and, field: type_column, operator: :eq, value: type_name}
      return Plan.new(where_fields, raw_columns)
    end

    key_sql = field_sql.call(foreign_key)
    type_sql = field_sql.call(type_column)
    by_type = {} of String => Array(Grant::Columns::Type)
    null_key = false
    entries.each do |key, entry_type|
      if entry_type
        (by_type[entry_type] ||= [] of Grant::Columns::Type) << key
      elsif key.nil?
        null_key = true
      else
        raise ArgumentError.new("#{model_name}##{name} is polymorphic; pass records so the type column can be matched")
      end
    end

    parts = [] of String
    values = [] of Grant::Columns::Type
    by_type.each do |grouped_type, keys|
      predicate, key_values = Grant::Query::KeyListPredicate.build(key_sql, keys)
      parts << "(#{predicate} AND #{type_sql} = ?)"
      values.concat(key_values)
      values << grouped_type
    end
    parts << "#{key_sql} IS NULL" if null_key
    predicate = "(#{parts.join(" OR ")})"
    where_fields << {join: join, stmt: predicate, values: values}
    raw_columns << {predicate, foreign_key, false}
    Plan.new(where_fields, raw_columns)
  end

  private def self.key_entries(value : T) : Array(KeyEntry) forall T
    entries = [] of KeyEntry
    if value.is_a?(Array)
      value.each { |item| entries.concat(key_entries(item)) }
    elsif value.is_a?(Grant::Base)
      key_name = value.class.primary_name || raise ArgumentError.new("#{value.class.name} has no primary key to match an association against")
      entries << {value.read_attribute(key_name).as(Grant::Columns::Type), value.class.polymorphic_name}
    elsif value.is_a?(Grant::Columns::Type)
      entries << {value, nil.as(String?)}
    else
      raise ArgumentError.new("Cannot compare an association with a #{value.class.name}")
    end
    entries
  end
end
