require "./association_scopes"

# Resolves an association into the simple steps ("hops") a JOIN or an EXISTS
# subquery walks: one hop for a direct association, the through hops followed
# by the source hops for a `through` association, to any depth.
module Grant::Query::AssociationHops
  # One owner-to-target step over a plain (non-through) association.
  struct Hop
    getter reflection : Grant::Reflection
    getter owner_class : Grant::Base.class
    getter target_class : Grant::Base.class
    # The class name stored in the type column when the step crosses a
    # polymorphic `belongs_to` read through `source_type:`.
    getter type_name : String?

    def initialize(@reflection : Grant::Reflection, @owner_class : Grant::Base.class, @target_class : Grant::Base.class, @type_name : String? = nil)
    end
  end

  # Raises `ArgumentError` for a path that has no single table to join: a
  # polymorphic `belongs_to`, a polymorphic through association, or a
  # polymorphic source without `source_type:`.
  def self.resolve(owner : Grant::Base.class, reflection : Grant::Reflection, label : String) : Array(Hop)
    through_name = reflection.through
    unless through_name
      if reflection.polymorphic?
        raise ArgumentError.new("Cannot use #{label} in a join or subquery: a polymorphic belongs_to has no single target table")
      end
      return [Hop.new(reflection, owner, reflection.klass)]
    end

    through_reflection = Grant::AssociationRegistry.reflection(owner.name, through_name)
    raise Grant::AssociationNotFoundError.new(owner.name, through_name) unless through_reflection
    if through_reflection.polymorphic?
      raise ArgumentError.new("Cannot use #{label} through the polymorphic association #{through_name.inspect}")
    end

    through_class = through_reflection.klass
    target = reflection.klass
    source_name = reflection.source || target.name.split("::").last.underscore
    source_reflection = Grant::AssociationRegistry.reflection(through_class.name, source_name)
    source_reflection ||= Grant::AssociationRegistry.reflection(through_class.name, reflection.name.rchop('s'))
    raise ArgumentError.new("Cannot resolve source #{source_name.inspect} for #{label}") unless source_reflection

    hops = resolve(owner, through_reflection, label)
    if source_reflection.polymorphic?
      unless reflection.options.has_key?("source_type")
        raise ArgumentError.new("Cannot use #{label}: its source #{source_name.inspect} is polymorphic, so the association needs source_type:")
      end
      hops << Hop.new(source_reflection, through_class, target, target.polymorphic_name)
    else
      hops.concat(resolve(through_class, source_reflection, label))
    end
    hops
  end

  # The join condition of *hop* between *owner_ref* and *target_ref* (quoted
  # table names or aliases). Bind values the condition needs (a polymorphic
  # type) are appended to *values*.
  def self.condition(hop : Hop, owner_ref : String, target_ref : String, values : Array(Grant::Columns::Type), quoted : Bool = true) : String
    reflection = hop.reflection
    quote = hop.target_class
    belongs = reflection.belongs_to?
    parent = belongs ? hop.target_class : hop.owner_class
    foreign_columns = reflection.foreign_key.split(',')
    primary_columns = if reflection.primary_key.empty?
                        Grant::CompositeAssociation.key_columns_named(parent.name) || [parent.primary_name.to_s]
                      else
                        reflection.primary_key.split(',')
                      end
    unless foreign_columns.size == primary_columns.size
      raise ArgumentError.new("#{reflection.owner_name}##{reflection.name}: the foreign key and primary key have different column counts")
    end

    name = ->(column : String) { quoted ? quote.quote(column) : column }
    parts = foreign_columns.map_with_index do |foreign, index|
      if belongs
        "#{target_ref}.#{name.call(primary_columns[index])} = #{owner_ref}.#{name.call(foreign)}"
      else
        "#{target_ref}.#{name.call(foreign)} = #{owner_ref}.#{name.call(primary_columns[index])}"
      end
    end

    if type_name = hop.type_name
      if type_column = reflection.foreign_type
        parts << "#{owner_ref}.#{name.call(type_column)} = ?"
        values << type_name
      end
    elsif !belongs && reflection.polymorphic_as && (type_column = reflection.foreign_type)
      parts << "#{target_ref}.#{name.call(type_column)} = ?"
      values << hop.owner_class.polymorphic_name
    end
    parts.join(" AND ")
  end

  # The registered scope of *reflection* as `(sql)` qualified by *qualifier*,
  # with its bind values appended to *values*; "" when it adds no condition.
  # Raises when the association is scoped but its scope cannot be rendered.
  def self.scope_condition(reflection : Grant::Reflection, qualifier : String, values : Array(Grant::Columns::Type)) : String
    return "" unless reflection.scope?

    unless Grant::AssociationRegistry.scope_renderer?(reflection.owner_name, reflection.name)
      raise ArgumentError.new("Cannot apply the scope of #{reflection.owner_name}##{reflection.name} in a query: it is not registered")
    end
    fragment = Grant::AssociationRegistry.scope_fragment(reflection.owner_name, reflection.name, qualifier)
    return "" unless fragment

    values.concat(fragment[1])
    "(#{fragment[0]})"
  end
end

class Grant::Query::Builder(Model)
  private def append_association_exists(name : String, negated : Bool) : Nil
    sql, values = association_exists_sql(name)
    own_where_fields << {join: :and, stmt: "#{negated ? "NOT " : ""}EXISTS (#{sql})", values: values}
  end

  # The `SELECT 1 FROM ...` subquery that is true when the record has a match
  # on *name*, with its bind values in text order. Association scopes (on the
  # association and on each step of a through path) apply to the table they
  # belong to, like the JOIN ActiveRecord builds.
  private def association_exists_sql(name : String) : Tuple(String, Array(Grant::Columns::Type))
    reflection = Grant::AssociationRegistry.reflection(Model.name, name) || raise Grant::AssociationNotFoundError.new(Model.name, name)
    hops = Grant::Query::AssociationHops.resolve(Model, reflection, "#{Model.name}##{name}")
    outer = Model.quote(Model.table_name)
    last = hops.size - 1
    aliases = hops.map_with_index do |_, index|
      if index == last
        Model.quote("assoc_target")
      elsif index == 0
        Model.quote("assoc_through")
      else
        Model.quote("assoc_through_#{index + 1}")
      end
    end

    values = [] of Grant::Columns::Type
    joins = [] of String
    (1..last).each do |index|
      hop = hops[index]
      conditions = [Grant::Query::AssociationHops.condition(hop, aliases[index - 1], aliases[index], values)]
      conditions << Grant::Query::AssociationHops.scope_condition(hop.reflection, aliases[index], values)
      if index == last && reflection.through?
        conditions << Grant::Query::AssociationHops.scope_condition(reflection, aliases[index], values)
      end
      joins << "INNER JOIN #{Model.quote(hop.target_class.table_name)} AS #{aliases[index]} ON #{conditions.reject(&.empty?).join(" AND ")}"
    end

    first = hops.first
    conditions = [Grant::Query::AssociationHops.condition(first, outer, aliases.first, values)]
    conditions << Grant::Query::AssociationHops.scope_condition(first.reflection, aliases.first, values)
    sql = String.build do |io|
      io << "SELECT 1 FROM " << Model.quote(first.target_class.table_name) << " AS " << aliases.first
      joins.each { |join| io << ' ' << join }
      io << " WHERE " << conditions.reject(&.empty?).join(" AND ")
    end
    {sql, values}
  end
end
