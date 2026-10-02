require "./batches"

# The remaining argument shapes of ActiveRecord's `Relation#update` and
# `update!`: a hash of attributes, one id with a hash, and a list of ids with a
# list of attribute hashes (each id gets its own). The keyword forms live in
# `Batches`.
module Grant::Query::Batches(Model)
  # Updates every matching record with *attributes* (a `Hash` or `NamedTuple`),
  # running validations and callbacks, and returns all matched records.
  #
  # ```
  # User.where(active: false).update({"active" => true})
  # ```
  def update(attributes : Hash | NamedTuple) : Array(Model)
    update_each(attributes, false)
  end

  # Like `update(attributes)`, but raises for the first record that cannot be
  # saved; that record's batch is rolled back. Wrap the call in
  # `Model.transaction` to roll back every record.
  def update!(attributes : Hash | NamedTuple) : Array(Model)
    update_each(attributes, true)
  end

  # Updates the record with primary key *id* inside this relation with the
  # given attribute hash and returns it.
  def update(id : Grant::Columns::Type, attributes : Hash | NamedTuple) : Model
    record = find_in_relation(id)
    record.update(attributes)
    record
  end

  # Like `update(id, attributes)`, but raises when the save fails.
  def update!(id : Grant::Columns::Type, attributes : Hash | NamedTuple) : Model
    record = find_in_relation(id)
    record.update!(attributes)
    record
  end

  # Updates each record named in *ids* with the attribute hash at the same
  # position in *attributes_list*, and returns the records in *ids* order. The
  # relation scopes the lookup: an id outside the relation raises
  # `Grant::Querying::NotFound`, and so does a size mismatch an `ArgumentError`.
  #
  # ```
  # User.where(active: true).update([1, 2], [{name: "Ada"}, {name: "Grace"}])
  # ```
  def update(ids : Array, attributes_list : Array) : Array(Model)
    update_many(ids, attributes_list, false)
  end

  # Like `update(ids, attributes_list)`, but raises for the first record that
  # cannot be saved.
  def update!(ids : Array, attributes_list : Array) : Array(Model)
    update_many(ids, attributes_list, true)
  end

  # `update(:all, **attributes)`, ActiveRecord's explicit spelling of "every
  # record in the relation".
  def update(scope : Symbol, **attributes) : Array(Model)
    raise ArgumentError.new("update takes :all or a primary key, not #{scope.inspect}") unless scope == :all

    update_each(attributes, false)
  end

  # :ditto:
  def update!(scope : Symbol, **attributes) : Array(Model)
    raise ArgumentError.new("update! takes :all or a primary key, not #{scope.inspect}") unless scope == :all

    update_each(attributes, true)
  end

  private def update_many(ids : Array, attributes_list : Array, bang : Bool) : Array(Model)
    Model.guard_writes!
    unless ids.size == attributes_list.size
      raise ArgumentError.new("update: #{ids.size} ids but #{attributes_list.size} attribute sets")
    end
    return [] of Model if ids.empty?

    unique = ids.uniq
    found = Hash(String, Model).new
    where({Model.primary_name.to_s => unique}).select.each { |record| found[record.primary_key_value.to_s] = record }
    missing = unique.reject { |id| found.has_key?(id.to_s) }
    raise Grant::Querying::NotFound.new("No #{Model.name} found for #{Model.primary_name} in (#{missing.join(", ")})") unless missing.empty?

    updated = [] of Model
    Model.transaction do
      ids.each_with_index do |id, index|
        record = found[id.to_s]
        bang ? record.update!(attributes_list[index]) : record.update(attributes_list[index])
        updated << record
      end
    end
    updated
  end
end

module Grant::Integrators
  # Updates each record named in *ids* with the attribute hash at the same
  # position in *attributes_list* and returns the records in *ids* order, like
  # ActiveRecord's `Model.update([1, 2], [{...}, {...}])`. Validations and
  # callbacks run; an id with no record raises `Grant::Querying::NotFound`.
  def update(ids : Array, attributes_list : Array)
    all.update(ids, attributes_list)
  end

  # Like `update(ids, attributes_list)`, but raises for the first record that
  # cannot be saved.
  def update!(ids : Array, attributes_list : Array)
    all.update!(ids, attributes_list)
  end
end
