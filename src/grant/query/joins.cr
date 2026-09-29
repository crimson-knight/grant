require "./builder"

# Resolves association names into JOIN clauses at build time from
# `Grant::AssociationRegistry`, so nothing is looked up per row.
module Grant::Query::JoinSupport
  alias Clause = NamedTuple(type: Symbol, table: String, on: String)

  # The name a joined table is referred to by in the rest of the query: its
  # alias for `"users AS managers"`, the table name otherwise.
  def self.qualifier(table : String) : String
    if index = table.rindex(/\s+as\s+/i)
      table[index..].sub(/\A\s+as\s+/i, "")
    else
      table
    end
  end

  RAW_JOIN_TARGET = /\bJOIN\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?(?!ON\b|USING\b|INNER\b|LEFT\b|RIGHT\b|FULL\b|CROSS\b|NATURAL\b|JOIN\b)([A-Za-z_][A-Za-z0-9_]*))?/i

  # Every name *clause* makes available to qualify columns with. A raw
  # fragment contributes each table (or its alias) it joins, so
  # `joins("INNER JOIN posts ON ...").where("posts.title": "x")` works.
  def self.qualifiers(clause : Clause) : Array(String)
    return [qualifier(clause[:table])] unless clause[:type] == :raw

    clause[:on].scan(RAW_JOIN_TARGET).map { |match| match[2]? || match[1] }
  end

  # `true` when one of *clauses* makes *name* available as a qualifier.
  def self.joins?(clauses : Array(Clause), name : String) : Bool
    clauses.any? { |clause| qualifiers(clause).includes?(name) }
  end

  # Resolves *association* on *owner* into join clauses of *type* (`:inner` or
  # `:left`). Naming *alias_name* joins the target table under that alias, which
  # is how a table is joined to itself.
  #
  # The ON condition depends on where the foreign key lives:
  #
  # - `belongs_to`: FK is on the owner's table, pointing at the target's PK.
  # - `has_many` / `has_one`: FK is on the target table, pointing back at the
  #   owner's PK.
  # - `has_many :through`: two clauses, owner to through table to target.
  #
  # Raises `ArgumentError` if the association is unknown.
  def self.resolve(owner : Grant::Base.class, association : Symbol, type : Symbol, alias_name : String? = nil) : Array(Clause)
    meta = Grant::AssociationRegistry.get(owner.name, association.to_s)
    raise ArgumentError.new("Unknown association #{association.inspect} for #{owner.name}") unless meta

    target_table = meta[:target_class].table_name
    current_table = owner.table_name
    foreign_key = meta[:foreign_key]
    primary_key = meta[:primary_key]

    if through_name = meta[:through]
      raise ArgumentError.new("A through association cannot be joined under an alias (#{association.inspect} on #{owner.name})") if alias_name

      through_meta = Grant::AssociationRegistry.get(owner.name, through_name)
      raise ArgumentError.new("Unknown through association #{through_name.inspect} for #{owner.name}") unless through_meta

      through_class = through_meta[:target_class]
      through_table = through_class.table_name
      first_on = "#{through_table}.#{through_meta[:foreign_key]} = #{current_table}.#{through_meta[:primary_key]}"

      source_name = meta[:source] || meta[:target_class].name.split("::").last.underscore
      source_meta = Grant::AssociationRegistry.get(through_class.name, source_name)
      source_foreign_key = if source = source_meta
                             source[:foreign_key]
                           else
                             "#{source_name}_id"
                           end
      source_primary_key = if source = source_meta
                             source[:primary_key]
                           else
                             meta[:target_class].primary_name
                           end

      second_on = if source_meta && source_meta[:type] == :belongs_to
                    "#{target_table}.#{source_primary_key} = #{through_table}.#{source_foreign_key}"
                  else
                    "#{target_table}.#{source_foreign_key} = #{through_table}.#{source_primary_key}"
                  end

      return [
        {type: type, table: through_table, on: first_on},
        {type: type, table: target_table, on: second_on},
      ]
    end

    reference = alias_name ? validated_alias(alias_name) : target_table
    on = case meta[:type]
         when :belongs_to
           # FK lives on the owner's table.
           "#{reference}.#{primary_key} = #{current_table}.#{foreign_key}"
         else
           # has_many / has_one: FK lives on the target table.
           "#{reference}.#{foreign_key} = #{current_table}.#{primary_key}"
         end

    table = alias_name ? "#{target_table} AS #{reference}" : target_table
    [{type: type, table: table, on: on}]
  end

  # Resolves a nested spec such as `{posts: :comments}` or
  # `{posts: [:comments, {likes: :user}]}` depth first, so each level joins from
  # the model the previous level reached.
  def self.resolve_nested(owner : Grant::Base.class, spec, type : Symbol) : Array(Clause)
    clauses = [] of Clause
    collect_nested(owner, spec, type, clauses)
    clauses
  end

  private def self.collect_nested(owner : Grant::Base.class, spec : Symbol, type : Symbol, into clauses : Array(Clause)) : Nil
    clauses.concat(resolve(owner, spec, type))
  end

  private def self.collect_nested(owner : Grant::Base.class, spec : Array, type : Symbol, into clauses : Array(Clause)) : Nil
    spec.each { |item| collect_nested(owner, item, type, clauses) }
  end

  private def self.collect_nested(owner : Grant::Base.class, spec : Hash | NamedTuple, type : Symbol, into clauses : Array(Clause)) : Nil
    spec.each do |name, nested|
      clauses.concat(resolve(owner, name, type))
      meta = Grant::AssociationRegistry.get(owner.name, name.to_s)
      raise ArgumentError.new("Unknown association #{name.inspect} for #{owner.name}") unless meta
      collect_nested(meta[:target_class], nested, type, clauses)
    end
  end

  private def self.validated_alias(name : String) : String
    unless name.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      raise ArgumentError.new("Join alias must be an identifier (got #{name.inspect})")
    end
    name
  end
end

class Grant::Query::Builder(Model)
  # Adds *clause* unless the relation already joins it, so the same association
  # requested through two paths (`joins(:posts).joins(posts: :comments)`) is
  # joined once.
  protected def add_join_clause(clause : Grant::Query::JoinSupport::Clause) : Nil
    return if @join_clauses.includes?(clause)
    own_join_clauses << clause
  end

  protected def add_join_clauses(clauses : Array(Grant::Query::JoinSupport::Clause)) : Nil
    clauses.each { |clause| add_join_clause(clause) }
  end

  # Adds a raw JOIN fragment such as `"INNER JOIN posts ON posts.user_id = users.id"`.
  # The fragment is trusted and emitted as written; it must be a single balanced
  # expression (no `;`, comment markers or unterminated quotes).
  #
  # ```
  # User.joins("INNER JOIN posts ON posts.user_id = users.id AND posts.published")
  # ```
  def joins!(sql : String) : self
    add_join_clause({type: :raw, table: "", on: Grant::Query::SqlExpression.validate!(sql, "JOIN fragment")})
    self
  end

  # Joins nested associations, resolved through the association registry from
  # the model each level reaches. A has_many chain multiplies rows; pair it with
  # `distinct` (or filter with `exists?`-style predicates) when the parent rows
  # are wanted once.
  #
  # ```
  # User.joins(posts: :comments)
  # User.joins(posts: [:comments, {likes: :user}])
  # ```
  def joins!(**nested) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve_nested(Model, nested, :inner))
    self
  end

  # Joins *association* under *as*, which is how a table is joined to itself.
  # The alias qualifies columns in `where("managers.name": ...)`.
  #
  # ```
  # # User belongs_to :manager (a User)
  # User.joins(:manager, as: "managers").where("managers.name": "Ada")
  # ```
  def joins!(association : Symbol, *, as as_name : String) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve(Model, association, :inner, as_name))
    self
  end

  def joins(sql : String) : self
    chain_copy.joins!(sql)
  end

  def joins(**nested) : self
    chain_copy.joins!(**nested)
  end

  def joins(association : Symbol, *, as as_name : String) : self
    chain_copy.joins!(association, as: as_name)
  end

  # LEFT JOIN counterparts of `joins`. A raw fragment is emitted as written, so
  # it carries its own `LEFT OUTER JOIN` keywords.
  def left_joins!(sql : String) : self
    joins!(sql)
  end

  def left_joins!(**nested) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve_nested(Model, nested, :left))
    self
  end

  def left_joins!(association : Symbol, *, as as_name : String) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve(Model, association, :left, as_name))
    self
  end

  def left_joins(sql : String) : self
    chain_copy.left_joins!(sql)
  end

  def left_joins(**nested) : self
    chain_copy.left_joins!(**nested)
  end

  def left_joins(association : Symbol, *, as as_name : String) : self
    chain_copy.left_joins!(association, as: as_name)
  end

  # `left_outer_joins` is ActiveRecord's name for `left_joins`; every form is
  # shared.
  def left_outer_joins!(table : String, *, on : String) : self
    left_joins!(table, on: on)
  end

  def left_outer_joins!(association : Symbol) : self
    left_joins!(association)
  end

  def left_outer_joins!(*associations : Symbol) : self
    left_joins!(*associations)
  end

  def left_outer_joins!(sql : String) : self
    left_joins!(sql)
  end

  def left_outer_joins!(**nested) : self
    left_joins!(**nested)
  end

  def left_outer_joins!(association : Symbol, *, as as_name : String) : self
    left_joins!(association, as: as_name)
  end

  def left_outer_joins(table : String, *, on : String) : self
    chain_copy.left_joins!(table, on: on)
  end

  def left_outer_joins(association : Symbol) : self
    chain_copy.left_joins!(association)
  end

  def left_outer_joins(*associations : Symbol) : self
    chain_copy.left_joins!(*associations)
  end

  def left_outer_joins(sql : String) : self
    chain_copy.left_joins!(sql)
  end

  def left_outer_joins(**nested) : self
    chain_copy.left_joins!(**nested)
  end

  def left_outer_joins(association : Symbol, *, as as_name : String) : self
    chain_copy.left_joins!(association, as: as_name)
  end
end
