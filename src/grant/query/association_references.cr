# `includes` that filters on an included association's table, and `eager_load`,
# load the association through a JOIN in ActiveRecord: the rows that match the
# WHERE are the rows the association holds. Grant loads associations in a second
# query, so it joins for the filter and then repeats the conditions that name
# only the association's table on that second query.
module Grant::Query::AssociationRestrictionSupport
  alias WhereField = Grant::Query::WhereField

  # Resolves which eager-loaded associations need joins and which WHERE
  # fields can safely be replayed while loading those associations.
  def self.resolve(model_name : String, includes : Array(Grant::Includes), eager_load : Array(Grant::Includes), where_fields : Array(WhereField), has_join_for_table : Proc(String, Bool), add_eager_load_join : Proc(Symbol, Nil)) : Hash(Symbol, Array(WhereField))
    restrictions = {} of Symbol => Array(WhereField)
    referenced = referenced_where_tables(where_fields)

    # Conditions render flat (`a OR b AND c`), so a condition taken out of an
    # OR chain would change meaning on the association query and drop rows the
    # join matched. With an OR present the association loads all its rows.
    replayable = where_fields.each_with_index.none? { |field, index| index > 0 && field[:join] == :or }
    (includes + eager_load).each do |spec|
      names = case spec
              when Symbol then [spec]
              when Hash   then spec.keys
              else             [] of Symbol
              end
      names.each do |name|
        next if restrictions.has_key?(name)
        reflection = Grant::AssociationRegistry.reflection(model_name, name.to_s)
        next unless reflection
        next if reflection.polymorphic? || reflection.through?
        target_table = reflection.klass.table_name
        joined = eager_load.any? { |eager| eager == name || (eager.is_a?(Hash) && eager.has_key?(name)) }
        next unless joined || referenced.includes?(target_table)

        add_eager_load_join.call(name) unless has_join_for_table.call(target_table)
        restrictions[name] = replayable ? where_fields_for_table(where_fields, target_table) : [] of WhereField
      end
    end
    restrictions
  end

  private def self.referenced_where_tables(where_fields : Array(WhereField)) : Set(String)
    tables = Set(String).new
    where_fields.each do |field|
      qualifiers_of(field).each { |qualifier| tables << qualifier }
    end
    tables
  end

  # The WHERE conditions that refer only to *table*, safe to replay on a query
  # over that table alone.
  private def self.where_fields_for_table(where_fields : Array(WhereField), table : String) : Array(WhereField)
    where_fields.select do |field|
      qualifiers = qualifiers_of(field)
      !qualifiers.empty? && qualifiers.all? { |qualifier| qualifier == table }
    end
  end

  private def self.qualifiers_of(field : WhereField) : Array(String)
    qualifiers = [] of String
    if field.is_a?(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
      parts = field[:field].split('.')
      qualifiers << parts.first if parts.size == 2
    elsif field.is_a?(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))
      scan_qualifiers(field[:stmt], qualifiers)
    elsif field.is_a?(NamedTuple(join: Symbol, stmt: String, values: Array(Grant::Columns::Type)))
      scan_qualifiers(field[:stmt], qualifiers)
    end
    qualifiers
  end

  private def self.scan_qualifiers(statement : String, into qualifiers : Array(String)) : Nil
    statement.scan(/(?<![\w.])"?([A-Za-z_][A-Za-z0-9_]*)"?\.(?=["A-Za-z_])/) do |match|
      qualifiers << match[1]
    end
  end
end

class Grant::Query::Builder(Model)
  # Joins the tables of included associations that the WHERE conditions refer
  # to (so `includes` behaves as `eager_load` there), and returns, for each
  # association loaded through a join, the conditions that mention only its table.
  protected def association_restrictions : Hash(Symbol, Array(WhereField))
    return {} of Symbol => Array(WhereField) if @relation_state.includes_associations.empty? && @relation_state.eager_load_associations.empty?

    Grant::Query::AssociationRestrictionSupport.resolve(
      Model.name, @relation_state.includes_associations, @relation_state.eager_load_associations, @relation_state.where_fields,
      ->(table : String) { @relation_state.join_clauses.any? { |clause| clause[:table] == table } },
      ->(association : Symbol) { add_eager_load_join(association); nil }
    )
  end
end
