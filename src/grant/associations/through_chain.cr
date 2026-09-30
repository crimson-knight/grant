module Grant::Associations
  # Raised when a `:through` association cannot be resolved into a chain of
  # joins, for example a polymorphic source without `source_type:`, a
  # polymorphic through association, or a name that is not an association.
  #
  # Mirrors ActiveRecord's `HasManyThroughAssociationPolymorphicSourceError`
  # and `HasManyThroughAssociationPolymorphicThroughError`.
  class ThroughChainError < Grant::ErrorBase
  end

  # The chain of direct associations a `:through` association walks from its
  # owner to its target, resolved from the registered reflections. A plain
  # `has_many :tags, through: :taggings` is two links; a through whose through
  # (or source) is itself a through, or whose source is polymorphic (with
  # `source_type:`), is resolved here.
  #
  # The chain becomes one statement: the target rows whose key is in a
  # sub-select that JOINs the intermediate tables, so a read never costs a
  # query per hop or per record. Chains are resolved once per association and
  # cached.
  #
  # ```
  # # Author -> posts -> comments -> reader, one statement:
  # class Author < Grant::Base
  #   has_many :posts
  #   has_many :comments, through: :posts
  #   has_many :readers, through: :comments, source: :reader
  # end
  # ```
  class ThroughChain
    # One hop: the model it arrives at, the column that leads into it on the
    # previous model and the column it is matched on, plus the type predicates
    # a polymorphic hop adds (`{column, stored class name}`). *from_type* is
    # tested on the previous model, *to_type* on the model it arrives at.
    record Link,
      model : Grant::Base.class,
      from_column : String,
      to_column : String,
      from_type : Tuple(String, String)? = nil,
      to_type : Tuple(String, String)? = nil

    @@cache = {} of Tuple(String, String) => ThroughChain?
    @@mutex = Mutex.new

    getter links : Array(Link)

    def initialize(@links : Array(Link))
    end

    # The chain of the `:through` association *name* on *owner*, or `nil` when
    # it is the plain two-hop form (an association through a direct one), which
    # the collection reads with its own join keys. Cached per association.
    def self.for(owner : Grant::Base.class, name : String) : ThroughChain?
      key = {owner.name, name}
      if @@cache.has_key?(key)
        return @@cache[key]
      end
      chain = resolve(owner, name)
      @@mutex.synchronize do
        updated = @@cache.dup
        updated[key] = chain
        @@cache = updated
      end
      chain
    end

    # True when *name* needs a chain rather than the plain two-hop form.
    private def self.chain_needed?(owner : Grant::Base.class, reflection : Grant::Reflection) : Bool
      return true if reflection.options.has_key?("source_type")
      through_name = reflection.through || return false
      through_reflection = Grant::AssociationRegistry.reflection(owner.name, through_name) ||
                           raise ThroughChainError.new("#{owner.name}##{reflection.name} goes through #{through_name}, which is not an association of #{owner.name}")
      return true if through_reflection.through? || through_reflection.polymorphic?
      source_name = reflection.source || return false
      source = Grant::AssociationRegistry.reflection(through_reflection.klass.name, source_name)
      !source.nil? && (source.through? || source.polymorphic?)
    end

    private def self.resolve(owner : Grant::Base.class, name : String) : ThroughChain?
      reflection = Grant::AssociationRegistry.reflection(owner.name, name) || return nil
      return nil unless reflection.through?
      return nil unless chain_needed?(owner, reflection)
      links = [] of Link
      append(links, owner, name, nil, false)
      new(links)
    end

    # Appends the links of the association *name* of *model* and returns the
    # model they arrive at. *target* and *source_type* carry the class a
    # polymorphic source resolves to.
    private def self.append(links : Array(Link), model : Grant::Base.class, name : String,
                            target : (Grant::Base.class)?, source_type : Bool) : Grant::Base.class
      reflection = Grant::AssociationRegistry.reflection(model.name, name) ||
                   raise ThroughChainError.new("#{model.name} has no association named #{name}")
      if through_name = reflection.through
        through_reflection = Grant::AssociationRegistry.reflection(model.name, through_name) ||
                             raise ThroughChainError.new("#{model.name}##{name} goes through #{through_name}, which is not an association of #{model.name}")
        if through_reflection.polymorphic?
          raise ThroughChainError.new("Cannot go through the polymorphic association #{model.name}##{through_name}; a through association needs a concrete model in the middle")
        end
        middle = append(links, model, through_name, nil, false)
        source_name = reflection.source || raise ThroughChainError.new("#{model.name}##{name} has no source association")
        append(links, middle, source_name, reflection.klass, reflection.options.has_key?("source_type"))
      else
        links << direct_link(model, reflection, target, source_type)
        links.last.model
      end
    end

    private def self.direct_link(model : Grant::Base.class, reflection : Grant::Reflection,
                                 target : (Grant::Base.class)?, source_type : Bool) : Link
      if reflection.belongs_to?
        if reflection.polymorphic?
          arrival = target if source_type
          unless arrival
            raise ThroughChainError.new("Cannot use the polymorphic association #{model.name}##{reflection.name} as a source without `source_type:`")
          end
          type_column = reflection.foreign_type || raise ThroughChainError.new("#{model.name}##{reflection.name} has no type column")
          key = reflection.options.has_key?("primary_key") ? reflection.primary_key : (arrival.primary_name || reflection.primary_key)
          Link.new(arrival, reflection.foreign_key, key, from_type: {type_column, arrival.polymorphic_name})
        else
          Link.new(reflection.klass, reflection.foreign_key, reflection.primary_key)
        end
      else
        key = reflection.options.has_key?("primary_key") ? reflection.primary_key : (model.primary_name || reflection.primary_key)
        type = if type_column = reflection.foreign_type
                 {type_column, model.polymorphic_name}
               end
        Link.new(reflection.klass, key, reflection.foreign_key, to_type: type)
      end
    end

    # The key of *owner* the first link starts from.
    def owner_key(owner : Grant::Base) : Grant::Columns::Type
      owner.read_attribute(@links.first.from_column)
    end

    # Restricts *relation* (of the target) to the rows reachable from *owner*
    # through every link: `target.key IN (SELECT ... JOIN ... WHERE first = ?)`.
    def restrict(relation : Grant::Query::Builder(T), owner : Grant::Base) : Grant::Query::Builder(T) forall T
      relation = relation.where("#{T.quote(@links.last.to_column)} IN (#{sub_select})", owner_key(owner))
      if type = @links.last.to_type
        relation = relation.where(type[0], :eq, type[1])
      end
      relation
    end

    # The `WHERE` fragment (with one `?` for the owner's key) for raw clauses.
    def where_clause(target : Grant::Base.class) : String
      predicates = ["#{target.quoted_table_name}.#{target.quote(@links.last.to_column)} IN (#{sub_select})"]
      if type = @links.last.to_type
        predicates << "#{target.quoted_table_name}.#{target.quote(type[0])} = #{literal(type[1])}"
      end
      "WHERE #{predicates.join(" AND ")}"
    end

    # `SELECT <key the last hop matches> FROM m1 JOIN m2 ... WHERE m1.key = ?`
    # over every model before the target. Tables are aliased so a model can
    # appear twice in one chain.
    private def sub_select : String
      last = @links.size - 1
      first = @links.first
      joins = String.build do |io|
        io << first.model.quoted_table_name << " AS " << alias_of(0)
        (1...last).each do |index|
          link = @links[index]
          previous = @links[index - 1]
          io << " JOIN " << link.model.quoted_table_name << " AS " << alias_of(index)
          io << " ON " << column(previous.model, index - 1, link.from_column) << " = " << column(link.model, index, link.to_column)
          if type = link.from_type
            io << " AND " << column(previous.model, index - 1, type[0]) << " = " << literal(type[1])
          end
          if type = link.to_type
            io << " AND " << column(link.model, index, type[0]) << " = " << literal(type[1])
          end
        end
      end
      predicates = ["#{column(first.model, 0, first.to_column)} = ?"]
      if type = first.to_type
        predicates << "#{column(first.model, 0, type[0])} = #{literal(type[1])}"
      end
      closing = @links.last
      if type = closing.from_type
        predicates << "#{column(@links[last - 1].model, last - 1, type[0])} = #{literal(type[1])}"
      end
      "SELECT #{column(@links[last - 1].model, last - 1, closing.from_column)} FROM #{joins} WHERE #{predicates.join(" AND ")}"
    end

    private def alias_of(index : Int32) : String
      "grant_hop_#{index}"
    end

    private def column(model : Grant::Base.class, index : Int32, name : String) : String
      "#{alias_of(index)}.#{model.quote(name)}"
    end

    # A type name written as an SQL string literal. Class names never hold
    # user input; the quote is doubled anyway.
    private def literal(value : String) : String
      "'#{value.gsub("'", "''")}'"
    end
  end
end
