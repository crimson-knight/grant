require "./transactions"
require "./querying"

module Grant::Integrators
  include Transactions::ClassMethods
  include Querying

  # Builds a record from *args*, yields it before it is saved, then saves it.
  # The record is returned even when the save failed; see `create!`.
  #
  # ```
  # User.create(email: "ada@example.com") { |user| user.role = "admin" }
  # ```
  def create(**args, &)
    create(args.to_h) { |record| yield record }
  end

  # :ditto:
  def create(args, skip_timestamps : Bool = false, &)
    guard_writes!
    instance = new
    instance.set_attributes(args.to_h.transform_keys(&.to_s))
    yield instance
    instance.save(skip_timestamps: skip_timestamps)
    instance
  end

  # Creates one record per element of *list*, all inside one transaction, and
  # returns them in order. Each record goes through validations and callbacks;
  # a record that fails validation is returned unsaved and does not stop the
  # others. Use `create!` to roll everything back on the first failure.
  #
  # ```
  # User.create([{name: "Ada"}, {name: "Grace"}]) # => [User, User]
  # ```
  def create(list : Array, skip_timestamps : Bool = false)
    guard_writes!
    created = [] of typeof(new)
    transaction do
      list.each { |args| created << create(args, skip_timestamps) }
    end
    created
  end

  # :ditto:
  def create(list : Array, skip_timestamps : Bool = false, &)
    guard_writes!
    created = [] of typeof(new)
    transaction do
      list.each { |args| created << create(args, skip_timestamps) { |record| yield record } }
    end
    created
  end

  # Like `create`, raising when the save fails.
  def create!(**args, &)
    create!(args.to_h) { |record| yield record }
  end

  # :ditto:
  def create!(args, skip_timestamps : Bool = false, &)
    guard_writes!
    instance = new
    instance.set_attributes(args.to_h.transform_keys(&.to_s))
    yield instance

    unless instance.save(skip_timestamps: skip_timestamps)
      if instance.errors.empty?
        instance.errors << Grant::Error.new(:base, "Save was halted before the record was persisted.")
      end
      raise instance.save_failure_error
    end

    instance
  end

  # Creates every record in *list* inside one transaction; the first failure
  # raises and rolls all of them back.
  def create!(list : Array, skip_timestamps : Bool = false)
    guard_writes!
    created = [] of typeof(new)
    transaction do
      list.each { |args| created << create!(args, skip_timestamps) }
    end
    created
  end

  # :ditto:
  def create!(list : Array, skip_timestamps : Bool = false, &)
    guard_writes!
    created = [] of typeof(new)
    transaction do
      list.each { |args| created << create!(args, skip_timestamps) { |record| yield record } }
    end
    created
  end

  def find_or_create_by(**args)
    find_by(**args) || create(**args)
  end

  # Finds by *args*, or creates with them; the block runs only on create.
  def find_or_create_by(**args, &)
    find_by(**args) || create(**args) { |record| yield record }
  end

  # Like `find_or_create_by`, raising when the create fails.
  def find_or_create_by!(**args)
    find_by(**args) || create!(**args)
  end

  # :ditto:
  def find_or_create_by!(**args, &)
    find_by(**args) || create!(**args) { |record| yield record }
  end

  def find_or_initialize_by(**args)
    find_by(**args) || new(**args)
  end

  # Finds by *args*, or builds (without saving) with them; the block runs only
  # when building.
  def find_or_initialize_by(**args, &)
    find_by(**args) || new(**args) { |record| yield record }
  end

  # Attributes-hash forms of `find_or_create_by`, `find_or_create_by!` and
  # `find_or_initialize_by`; the block runs only when a record is built.
  #
  # ```
  # User.find_or_create_by({"email" => "ada@example.com"})
  # ```
  def find_or_create_by(args : Grant::ModelArgs)
    find_by(args) || create(args)
  end

  # :ditto:
  def find_or_create_by(args : Grant::ModelArgs, &)
    find_by(args) || create(args) { |record| yield record }
  end

  # :ditto:
  def find_or_create_by!(args : Grant::ModelArgs)
    find_by(args) || create!(args)
  end

  # :ditto:
  def find_or_create_by!(args : Grant::ModelArgs, &)
    find_by(args) || create!(args) { |record| yield record }
  end

  # :ditto:
  def find_or_initialize_by(args : Grant::ModelArgs)
    find_by(args) || new(args)
  end

  # :ditto:
  def find_or_initialize_by(args : Grant::ModelArgs, &)
    find_by(args) || new(args) { |record| yield record }
  end

  # Class-level forms of the relation methods below start from `current_scope`,
  # so a default scope's equality predicates seed the new record.
  {% for name in %w(create_or_find_by create_or_find_by! first_or_create first_or_create! first_or_initialize) %}
    def {{name.id}}(**attrs : Grant::Columns::Type)
      current_scope.{{name.id}}(**attrs)
    end

    # :ditto:
    def {{name.id}}(**attrs : Grant::Columns::Type, &block : self ->)
      current_scope.{{name.id}}(**attrs, &block)
    end
  {% end %}

  # Relation with `create_with` defaults, see `Grant::Query::Finders#create_with`.
  def create_with(**attrs : Grant::Columns::Type)
    current_scope.create_with(**attrs)
  end

  # The equality attributes a new record starts with, see
  # `Grant::Query::Finders#scope_attributes`.
  def scope_attributes : Hash(String, Grant::Columns::Type)
    current_scope.scope_attributes
  end

  # Destroys the record with primary key *id*, running callbacks, and returns
  # it. Raises `Grant::Querying::NotFound` when there is none.
  def destroy(id : Grant::Querying::IdValue)
    guard_writes!
    record = find!(id)
    record.destroy
    record
  end

  # Destroys the records with the given primary keys: one `SELECT ... IN`,
  # then a callback-running destroy per record. Raises
  # `Grant::Querying::NotFound` naming any key with no record.
  def destroy(ids : Array)
    guard_writes!
    records = find!(ids)
    records.each(&.destroy)
    records
  end

  # Updates the record with primary key *id* (validations and callbacks run)
  # and returns it; check `errors` when the update was rejected. Raises
  # `Grant::Querying::NotFound` when there is none.
  def update(id : Grant::Querying::IdValue, **attrs)
    update(id, attrs.to_h)
  end

  # :ditto:
  def update(id : Grant::Querying::IdValue, attrs)
    guard_writes!
    record = find!(id)
    record.update(attrs)
    record
  end

  # Updates every record with the given primary keys with the same *attrs*:
  # one `SELECT ... IN`, then an update per record.
  def update(ids : Array, **attrs)
    update(ids, attrs.to_h)
  end

  # :ditto:
  def update(ids : Array, attrs)
    guard_writes!
    records = find!(ids)
    records.each(&.update(attrs))
    records
  end
end
