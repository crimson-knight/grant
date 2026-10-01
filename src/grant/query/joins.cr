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

  # Collects the JOIN clauses a set of association names produces for one
  # relation. It knows which tables the relation already uses, so a table
  # reached a second time through a different association or path is joined
  # under an alias (`comments_posts`) instead of being emitted twice, and a
  # clause the relation already holds is not added again.
  class Collector
    getter added = [] of Clause
    @existing : Array(Clause)

    def initialize(@root_table : String, existing : Array(Clause) = [] of Clause)
      @existing = existing
    end

    # Joins *association* of *owner*, reached from the table or alias
    # *owner_ref*, and returns the name the target table is known by. Naming
    # *alias_name* joins the target under that alias.
    def step(owner : Grant::Base.class, association : Symbol, type : Symbol, owner_ref : String, alias_name : String? = nil) : String
      reflection = Grant::AssociationRegistry.reflection(owner.name, association.to_s)
      if reflection && reflection.polymorphic?
        raise ArgumentError.new("Cannot join #{owner.name}##{association}: a polymorphic belongs_to has no single target table")
      end
      meta = Grant::AssociationRegistry.get(owner.name, association.to_s)
      raise ArgumentError.new("Unknown association #{association.inspect} for #{owner.name}") unless meta

      target_class = meta[:target_class]
      target_table = target_class.table_name
      foreign_key = meta[:foreign_key]
      primary_key = meta[:primary_key]

      if meta[:through]
        raise ArgumentError.new("A through association cannot be joined under an alias (#{association.inspect} on #{owner.name})") if alias_name
        raise ArgumentError.new("Unknown association #{association.inspect} for #{owner.name}") unless reflection

        # Every hop of the path (through steps, then source steps, to any
        # depth) is one clause; each hop's own scope goes in its ON.
        hops = Grant::Query::AssociationHops.resolve(owner, reflection, "#{owner.name}##{association}")
        ref = owner_ref
        hops.each_with_index do |hop, index|
          parent = ref
          last = index == hops.size - 1
          ref = emit(type, hop.target_class.table_name, nil, hop.reflection.name, parent) do |target_ref|
            values = [] of Grant::Columns::Type
            on = Grant::Query::AssociationHops.condition(hop, parent, target_ref, values, quoted: false)
            on = inline(on, values, owner)
            on = with_scope(on, hop.reflection, target_ref, owner)
            last ? with_scope(on, reflection, target_ref, owner) : on
          end
        end
        return ref
      end

      emit(type, target_table, alias_name, association.to_s, owner_ref) do |ref|
        on = if Grant::CompositeAssociation.composite?(foreign_key)
               Grant::CompositeAssociation.join_on(meta[:type] == :belongs_to, owner, target_class, ref, owner_ref, foreign_key, primary_key)
             elsif meta[:type] == :belongs_to
               "#{ref}.#{primary_key} = #{owner_ref}.#{foreign_key}"
             else
               "#{ref}.#{foreign_key} = #{owner_ref}.#{primary_key}"
             end
        with_scope(on, reflection, ref, owner)
      end
    end

    # Joins the associations *spec* names (`:posts`, `[:a, :b]`, `{posts: :comments}`)
    # depth first, each level from the table the previous level reached.
    def nested(owner : Grant::Base.class, spec : Symbol, type : Symbol, owner_ref : String) : Nil
      step(owner, spec, type, owner_ref)
    end

    def nested(owner : Grant::Base.class, spec : Array, type : Symbol, owner_ref : String) : Nil
      spec.each { |item| nested(owner, item, type, owner_ref) }
    end

    def nested(owner : Grant::Base.class, spec : Hash | NamedTuple, type : Symbol, owner_ref : String) : Nil
      spec.each do |name, children|
        target_ref = step(owner, name, type, owner_ref)
        meta = Grant::AssociationRegistry.get(owner.name, name.to_s)
        raise ArgumentError.new("Unknown association #{name.inspect} for #{owner.name}") unless meta
        nested(meta[:target_class], children, type, target_ref)
      end
    end

    # Adds the clause for *table*, reached through *name_hint* from
    # *parent_ref*, and returns the reference the clause's table is known by.
    # The block builds the ON condition for a given reference.
    private def emit(type : Symbol, table : String, alias_name : String?, name_hint : String, parent_ref : String, & : String -> String) : String
      if alias_name
        ref = JoinSupport.validated_alias(alias_name)
        add({type: type, table: "#{table} AS #{ref}", on: yield ref})
        return ref
      end

      plain = {type: type, table: table, on: yield table}
      return table if holds?(plain)
      unless used?(table)
        @added << plain
        return table
      end

      plural = name_hint.ends_with?('s') ? name_hint : Grant::CounterCache.pluralize(name_hint)
      base = "#{plural}_#{parent_ref}"
      ref = base
      suffix = 1
      loop do
        clause = {type: type, table: "#{table} AS #{ref}", on: yield ref}
        return ref if holds?(clause)
        unless used?(ref)
          @added << clause
          return ref
        end
        suffix += 1
        ref = "#{base}_#{suffix}"
      end
    end

    private def add(clause : Clause) : Nil
      @added << clause unless holds?(clause)
    end

    private def holds?(clause : Clause) : Bool
      @existing.includes?(clause) || @added.includes?(clause)
    end

    private def used?(name : String) : Bool
      name == @root_table || JoinSupport.joins?(@existing, name) || JoinSupport.joins?(@added, name)
    end

    # *on* with the scope of *reflection* appended, columns qualified by *ref*.
    # Values are written into the SQL as quoted literals, because a JOIN clause
    # carries no bind values.
    private def with_scope(on : String, reflection : Grant::Reflection?, ref : String, owner : Grant::Base.class) : String
      return on unless reflection && reflection.scope?
      unless Grant::AssociationRegistry.scope_renderer?(reflection.owner_name, reflection.name)
        raise ArgumentError.new("Cannot apply the scope of #{reflection.owner_name}##{reflection.name} in a join: it is not registered")
      end

      fragment = Grant::AssociationRegistry.scope_fragment(reflection.owner_name, reflection.name, ref)
      return on unless fragment

      "#{on} AND (#{inline(fragment[0], fragment[1], owner)})"
    end

    private def inline(sql : String, values : Array(Grant::Columns::Type), owner : Grant::Base.class) : String
      return sql if values.empty?

      arguments = [] of Grant::Columns::Type
      arguments << sql
      arguments.concat(values)
      Grant::Sanitization.sanitize_sql_array(arguments, owner.adapter)
    end
  end

  # Resolves *association* on *owner* into join clauses of *type* (`:inner` or
  # `:left`). Naming *alias_name* joins the target table under that alias, which
  # is how a table is joined to itself. A scope declared on the association
  # (and on each step of a through path) is part of the ON condition.
  #
  # The ON condition depends on where the foreign key lives:
  #
  # - `belongs_to`: FK is on the owner's table, pointing at the target's PK.
  # - `has_many` / `has_one`: FK is on the target table, pointing back at the
  #   owner's PK.
  # - `has_many :through`: two clauses, owner to through table to target.
  #
  # Raises `ArgumentError` if the association is unknown or polymorphic.
  def self.resolve(owner : Grant::Base.class, association : Symbol, type : Symbol, alias_name : String? = nil, existing : Array(Clause) = [] of Clause, root_table : String = owner.table_name) : Array(Clause)
    collector = Collector.new(root_table, existing)
    collector.step(owner, association, type, owner.table_name, alias_name)
    collector.added
  end

  # Resolves a nested spec such as `{posts: :comments}` or
  # `{posts: [:comments, {likes: :user}]}` depth first, so each level joins from
  # the model the previous level reached. A table reached twice is aliased.
  def self.resolve_nested(owner : Grant::Base.class, spec, type : Symbol, existing : Array(Clause) = [] of Clause, root_table : String = owner.table_name) : Array(Clause)
    collector = Collector.new(root_table, existing)
    collector.nested(owner, spec, type, owner.table_name)
    collector.added
  end

  def self.validated_alias(name : String) : String
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

  # Adds a raw JOIN fragment whose `?` placeholders are replaced by the quoted
  # *binds*, left to right. The values are written into the SQL as literals (a
  # JOIN clause carries no bind values of its own), so they are escaped by
  # `Grant::Sanitization`; the fragment itself is still trusted.
  #
  # ```
  # User.joins("INNER JOIN posts ON posts.user_id = users.id AND posts.score > ?", 10)
  # ```
  def joins!(sql : String, binds : Array) : self
    validated = Grant::Query::SqlExpression.validate!(sql, "JOIN fragment")
    arguments = [] of Grant::Columns::Type
    arguments << validated
    binds.each { |value| arguments << value.as(Grant::Columns::Type) }
    add_join_clause({type: :raw, table: "", on: Grant::Sanitization.sanitize_sql_array(arguments, Model.adapter)})
    self
  end

  # :ditto:
  def joins!(sql : String, first, *rest) : self
    joins!(sql, [first, *rest])
  end

  # Joins only nested associations (`joins(posts: :comments)`); see the
  # positional form for mixing plain names with nested ones.
  def joins!(**nested) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve_nested(Model, nested, :inner, @join_clauses))
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
    add_join_clauses(Grant::Query::JoinSupport.resolve(Model, association, :inner, as_name, @join_clauses))
    self
  end

  def joins(sql : String) : self
    chain_copy.joins!(sql)
  end

  def joins(sql : String, binds : Array) : self
    chain_copy.joins!(sql, binds)
  end

  def joins(sql : String, first, *rest) : self
    chain_copy.joins!(sql, first, *rest)
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

  def left_joins!(sql : String, binds : Array) : self
    joins!(sql, binds)
  end

  def left_joins!(sql : String, first, *rest) : self
    joins!(sql, first, *rest)
  end

  def left_joins!(**nested) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve_nested(Model, nested, :left, @join_clauses))
    self
  end

  def left_joins!(association : Symbol, *, as as_name : String) : self
    add_join_clauses(Grant::Query::JoinSupport.resolve(Model, association, :left, as_name, @join_clauses))
    self
  end

  def left_joins(sql : String) : self
    chain_copy.left_joins!(sql)
  end

  def left_joins(sql : String, binds : Array) : self
    chain_copy.left_joins!(sql, binds)
  end

  def left_joins(sql : String, first, *rest) : self
    chain_copy.left_joins!(sql, first, *rest)
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

  def left_outer_joins!(*associations : Symbol, **nested) : self
    left_joins!(*associations, **nested)
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

  def left_outer_joins(*associations : Symbol, **nested) : self
    chain_copy.left_joins!(*associations, **nested)
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

require "./association_exists"
