# Association scope lambdas, reachable at run time.
#
# A scope declared on an association (`has_many :posts, -> { where(published: true) }`)
# is a lambda over the target's relation. Queries that reach the association
# through a JOIN or an EXISTS subquery (`joins`, `left_joins`, `where.associated`,
# `where.missing`) need its WHERE conditions as SQL, so every scoped association
# registers a renderer here when the program starts.
class Grant::AssociationRegistry
  # A scope condition as SQL text with `?` placeholders, plus the bind values
  # in the order the placeholders appear.
  alias ScopeFragment = Tuple(String, Array(Grant::Columns::Type))

  # Renders the scope with the target's columns qualified by the given
  # (already quoted) table reference.
  alias ScopeRenderer = Proc(String, ScopeFragment?)

  @@scopes = {} of String => Hash(String, ScopeRenderer)

  def self.register_scope(model_class : String, association_name : String, renderer : ScopeRenderer) : Nil
    @@mutex.synchronize do
      updated = @@scopes.dup
      per_model = updated[model_class]?.try(&.dup) || {} of String => ScopeRenderer
      per_model[association_name] = renderer
      updated[model_class] = per_model
      @@scopes = updated
    end
  end

  # The WHERE conditions of the scope declared on *association_name*, qualified
  # by *qualifier* (a quoted table name or alias), or nil when the association
  # has no scope or the scope adds no condition.
  def self.scope_fragment(model_class : String, association_name : String, qualifier : String) : ScopeFragment?
    @@scopes[model_class]?.try(&.[association_name]?).try(&.call(qualifier))
  end

  # True when a renderer exists for the association (a scoped association
  # declared through a path the registration cannot see has none).
  def self.scope_renderer?(model_class : String, association_name : String) : Bool
    !@@scopes[model_class]?.try(&.[association_name]?).nil?
  end
end

class Grant::Query::Builder(Model)
  # The relation's WHERE conditions as SQL with `?` placeholders, columns
  # qualified by *qualifier* in place of the model's own table name. Used to
  # apply an association scope inside a JOIN ... ON or an EXISTS subquery.
  #
  # :nodoc:
  def association_scope_fragment(qualifier : String) : Grant::AssociationRegistry::ScopeFragment?
    return if @relation_state.where_fields.empty?

    renderer = assembler
    sql = renderer.where_group_sql(@relation_state.where_fields)
    values = renderer.numbered_parameters.dup
    return if sql.empty?

    sql = sql.gsub(/\$\d+/, "?") if @relation_state.db_type.pg?
    table = Model.table_name
    sql = sql.gsub("#{Model.quote(table)}.", "#{qualifier}.")
    sql = sql.gsub(/(?<![\w."`])#{Regex.escape(table)}\./, "#{qualifier}.")
    {sql, values}
  end
end

# Registers the scope of every scoped association once all models exist. Each
# registration is emitted inside its model's body, so the scope lambda sees the
# model's constants and class methods exactly as it does where it was declared.
macro finished
  {% for model in Grant::Base.all_subclasses %}
    {% scoped = model.methods.select { |method| (ann = method.annotation(Grant::Relationship)) && ann[:scope].is_a?(ProcLiteral) && ann[:target] && ann[:target].resolve? } %}
    {% unless scoped.empty? %}
      class ::{{model.name}}
        {% for method in scoped %}
          {% ann = method.annotation(Grant::Relationship) %}
          {% scope = ann[:scope] %}
          Grant::AssociationRegistry.register_scope(
            {{model.name.stringify}}, {{method.name.stringify}},
            ->(qualifier : String) : Grant::AssociationRegistry::ScopeFragment? {
              relation = {{ann[:target].resolve}}.unscoped
              {% if scope.args.empty? %}
                relation = relation.{{scope.body}}
              {% else %}
                relation = {{scope}}.call(relation)
              {% end %}
              relation.association_scope_fragment(qualifier)
            })
        {% end %}
      end
    {% end %}
  {% end %}
end
