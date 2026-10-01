# Finders of `Grant::AssociationCollection`: the ordinal readers (`first`,
# `last(n)`, `take`, `second` ...), `find` by one or several keys, and the
# `find_or_*` family. They read the loaded records when the collection is
# loaded (or holds unsaved records) and otherwise run one `LIMIT` query within
# the owner scope, never loading the association.
class Grant::AssociationCollection(Owner, Target)
  def where(**matches) : Grant::Query::Builder(Target)
    scope.where(**matches)
  end

  # The first record by primary key, or `nil`.
  def first : Target?
    if records = memory_records
      records.first?
    else
      adopt(scope.first)
    end
  end

  # Like `first`, raising `Grant::Querying::NotFound` when there is none.
  def first! : Target
    first || raise Grant::Querying::NotFound.new("No #{Target.name} found")
  end

  # The first *n* records by primary key with `LIMIT n`.
  #
  # ```
  # user.posts.first(3)
  # ```
  def first(n : Int32) : Array(Target)
    if records = memory_records
      records.first(n)
    else
      adopt(scope.first(n))
    end
  end

  # The last record by primary key (`ORDER BY ... DESC LIMIT 1`), or `nil`.
  def last : Target?
    if records = memory_records
      records.last?
    else
      adopt(scope.last)
    end
  end

  # Like `last`, raising `Grant::Querying::NotFound` when there is none.
  def last! : Target
    last || raise Grant::Querying::NotFound.new("No #{Target.name} found")
  end

  # The last *n* records, in ascending order.
  def last(n : Int32) : Array(Target)
    if records = memory_records
      records.last(n)
    else
      adopt(scope.last(n))
    end
  end

  # One record with no ordering (`LIMIT 1`), or `nil`.
  def take : Target?
    if records = memory_records
      records.first?
    else
      adopt(scope.take)
    end
  end

  # Up to *n* records with no ordering.
  def take(n : Int32) : Array(Target)
    if records = memory_records
      records.first(n)
    else
      adopt(scope.take(n))
    end
  end

  # Like `take`, raising `Grant::Querying::NotFound` when there is none.
  def take! : Target
    take || raise Grant::Querying::NotFound.new("No #{Target.name} found")
  end

  {% for pair in [{"second", 1}, {"third", 2}, {"fourth", 3}, {"fifth", 4}, {"forty_two", 41}] %}
    # The {{pair[0].id}} record by primary key (`LIMIT 1 OFFSET {{pair[1]}}`), or `nil`.
    def {{pair[0].id}} : Target?
      if records = memory_records
        records[{{pair[1]}}]?
      else
        adopt(scope.{{pair[0].id}})
      end
    end

    # Like `{{pair[0].id}}`, raising `Grant::Querying::NotFound` when there is none.
    def {{pair[0].id}}! : Target
      {{pair[0].id}} || raise Grant::Querying::NotFound.new("No #{Target.name} found")
    end
  {% end %}

  {% for pair in [{"second_to_last", 1}, {"third_to_last", 2}] %}
    # The {{pair[0].id.gsub(/_/, " ")}} record, counting from the end, or `nil`.
    def {{pair[0].id}} : Target?
      if records = memory_records
        records[-{{pair[1] + 1}}]?
      else
        adopt(scope.{{pair[0].id}})
      end
    end

    # Like `{{pair[0].id}}`, raising `Grant::Querying::NotFound` when there is none.
    def {{pair[0].id}}! : Target
      {{pair[0].id}} || raise Grant::Querying::NotFound.new("No #{Target.name} found")
    end
  {% end %}

  # The record with primary key *value* within the association, or `nil`.
  def find(value) : Target?
    record = if records = memory_records
               records.find { |item| item.primary_key_value.to_s == value.to_s }
             else
               adopt(scope.where(Target.primary_name, :eq, value.as(Grant::Columns::Type)).first)
             end
    set_inverse(record) if record
    record
  end

  # The records with the primary keys in *ids*, in that order, with one `IN`
  # query. A key with no record in the association is skipped; see `find!`.
  def find(ids : Array) : Array(Target)
    if records = memory_records
      wanted = ids.map(&.to_s)
      wanted.compact_map { |key| records.find { |item| item.primary_key_value.to_s == key } }
    else
      adopt(scope.find(ids))
    end
  end

  # :ditto:
  def find(first, second, *rest) : Array(Target)
    find([first, second, *rest])
  end

  def find!(value) : Target
    find(value) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{Target.primary_name} = #{value}")
  end

  # Like `find(ids)`, raising `Grant::Querying::NotFound` naming every key that
  # has no record in the association.
  def find!(ids : Array) : Array(Target)
    found = find(ids)
    if found.size != ids.size
      known = found.map { |record| record.primary_key_value.to_s }
      missing = ids.reject { |key| known.includes?(key.to_s) }
      raise Grant::Querying::NotFound.new("Couldn't find all #{Target.name} with '#{Target.primary_name}': (#{ids.join(", ")}) (found #{found.size} results, but was looking for #{ids.size}; missing: #{missing.join(", ")})")
    end
    found
  end

  # :ditto:
  def find!(first, second, *rest) : Array(Target)
    find!([first, second, *rest])
  end

  # The record matching *attrs*, or a new one built on this collection (owner
  # key set, not saved).
  #
  # ```
  # user.posts.find_or_initialize_by(title: "Hello")
  # ```
  def find_or_initialize_by(**attrs) : Target
    find_by(model_args(attrs)) || build(**attrs)
  end

  # :ditto:
  def find_or_initialize_by(**attrs, &block : Target ->) : Target
    find_by(model_args(attrs)) || build(**attrs, &block)
  end

  # :ditto:
  def find_or_initialize_by(attrs : Hash) : Target
    find_by(model_args(attrs)) || build(attrs)
  end

  # :ditto:
  def find_or_initialize_by(attrs : Hash, &block : Target ->) : Target
    find_by(model_args(attrs)) || build(attrs, &block)
  end

  # The record matching *attrs*, or one created through this collection, so the
  # owner key (and a `:through` join row) is applied. The block runs only when
  # a record is created. Raises `Grant::Associations::OwnerNotSaved` when it
  # has to create on an unsaved owner.
  #
  # ```
  # user.posts.find_or_create_by(title: "Hello")
  # ```
  def find_or_create_by(**attrs) : Target
    find_by(model_args(attrs)) || create(**attrs)
  end

  # :ditto:
  def find_or_create_by(**attrs, &block : Target ->) : Target
    find_by(model_args(attrs)) || create(**attrs, &block)
  end

  # :ditto:
  def find_or_create_by(attrs : Hash) : Target
    find_by(model_args(attrs)) || create(attrs)
  end

  # :ditto:
  def find_or_create_by(attrs : Hash, &block : Target ->) : Target
    find_by(model_args(attrs)) || create(attrs, &block)
  end

  # Like `find_or_create_by`, raising when the create fails.
  def find_or_create_by!(**attrs) : Target
    find_by(model_args(attrs)) || create!(**attrs)
  end

  # :ditto:
  def find_or_create_by!(**attrs, &block : Target ->) : Target
    find_by(model_args(attrs)) || create!(**attrs, &block)
  end

  # :ditto:
  def find_or_create_by!(attrs : Hash) : Target
    find_by(model_args(attrs)) || create!(attrs)
  end

  # :ditto:
  def find_or_create_by!(attrs : Hash, &block : Target ->) : Target
    find_by(model_args(attrs)) || create!(attrs, &block)
  end

  # Creates through this collection inside a savepoint and looks the record up
  # when a unique constraint wins the race, so it needs no prior SELECT (the
  # race-safe form of `find_or_create_by`).
  #
  # ```
  # user.posts.create_or_find_by(slug: "hello")
  # ```
  def create_or_find_by(**attrs) : Target
    create_or_find(model_args(attrs), false, nil)
  end

  # :ditto:
  def create_or_find_by(**attrs, &block : Target ->) : Target
    create_or_find(model_args(attrs), false, block)
  end

  # :ditto:
  def create_or_find_by(attrs : Hash) : Target
    create_or_find(model_args(attrs), false, nil)
  end

  # :ditto:
  def create_or_find_by(attrs : Hash, &block : Target ->) : Target
    create_or_find(model_args(attrs), false, block)
  end

  # Like `create_or_find_by`, raising when the create fails for any other reason.
  def create_or_find_by!(**attrs) : Target
    create_or_find(model_args(attrs), true, nil)
  end

  # :ditto:
  def create_or_find_by!(**attrs, &block : Target ->) : Target
    create_or_find(model_args(attrs), true, block)
  end

  # :ditto:
  def create_or_find_by!(attrs : Hash) : Target
    create_or_find(model_args(attrs), true, nil)
  end

  # :ditto:
  def create_or_find_by!(attrs : Hash, &block : Target ->) : Target
    create_or_find(model_args(attrs), true, block)
  end

  private def create_or_find(args : Grant::ModelArgs, bang : Bool, block : Proc(Target, Nil)?) : Target
    record = nil.as(Target?)
    begin
      Owner.transaction(requires_new: true) do
        record = create_record(args, bang) { |built| block.try(&.call(built)) }
      end
    rescue error : Grant::RecordNotSaved
      raise error unless error.statement_error.is_a?(Grant::RecordNotUnique)
      return find_by!(args)
    end
    created = record || raise Grant::Querying::NotFound.new("No #{Target.name} created")
    return created if created.persisted?
    return created unless created.save_failure_error.statement_error.is_a?(Grant::RecordNotUnique)

    find_by(args) || created
  end
end
