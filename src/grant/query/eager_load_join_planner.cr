require "./builder"

# Builds the two JOIN clauses used by eager loading through and polymorphic
# associations. The relation builder supplies its model class and consumes
# plain clauses, so the reflection traversal and SQL assembly compile once.
# :nodoc:
module Grant::Query::EagerLoadJoinPlanner
  alias Clause = Grant::Query::JoinSupport::Clause

  def self.polymorphic_as(owner_model : Grant::Base.class, reflection : Grant::Reflection) : Clause?
    target_model = reflection.klass
    type_column = reflection.foreign_type
    return unless type_column

    type_name = owner_model.polymorphic_name.gsub("'", "''")
    on = "#{target_model.quote(target_model.table_name)}.#{target_model.quote(reflection.foreign_key)} = #{owner_model.quote(owner_model.table_name)}.#{owner_model.quote(reflection.primary_key)}" \
         " AND #{target_model.quote(target_model.table_name)}.#{target_model.quote(type_column)} = '#{type_name}'"
    {type: :left, table: target_model.table_name, on: on}
  end

  def self.through(owner_model : Grant::Base.class, metadata : Grant::AssociationRegistry::AssociationMeta) : Array(Clause)?
    through_name = metadata[:through]
    source_name = metadata[:source]
    return unless through_name && source_name

    through_metadata = Grant::AssociationRegistry.get(owner_model.name, through_name)
    return unless through_metadata
    source_metadata = Grant::AssociationRegistry.get(through_metadata[:target_class].name, source_name)
    return unless source_metadata

    through_model = through_metadata[:target_class]
    target_model = metadata[:target_class]
    owner_join = "#{through_model.quote(through_model.table_name)}.#{through_model.quote(through_metadata[:foreign_key])} = #{owner_model.quote(owner_model.table_name)}.#{owner_model.quote(through_metadata[:primary_key])}"

    target_join = if source_metadata[:type] == :belongs_to
                    "#{target_model.quote(target_model.table_name)}.#{target_model.quote(source_metadata[:primary_key])} = #{through_model.quote(through_model.table_name)}.#{through_model.quote(source_metadata[:foreign_key])}"
                  else
                    "#{target_model.quote(target_model.table_name)}.#{target_model.quote(source_metadata[:foreign_key])} = #{through_model.quote(through_model.table_name)}.#{through_model.quote(source_metadata[:primary_key])}"
                  end

    [
      {type: :left, table: through_model.table_name, on: owner_join},
      {type: :left, table: target_model.table_name, on: target_join},
    ]
  end
end
