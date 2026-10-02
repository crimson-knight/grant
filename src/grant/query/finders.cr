# Finder and build/create conveniences shared by every relation
# (`Grant::Query::Builder` and the named-scope relations derived from it).
#
# Building a record from a relation starts from the relation's *scope
# attributes*: the literal equality predicates of its `where` clauses (and its
# default scope), so `Post.where(published: true).create(title: "x")` inserts a
# published post. Ranges, `IN` lists, `OR` groups, raw SQL and other operators
# never produce defaults. `create_with` layers explicit defaults on top of the
# scope attributes, and the attributes passed to the call win over both.
#
# ```
# scope = Post.where(author_id: 7).create_with(status: "draft")
# scope.find_or_create_by(title: "Hello") # WHERE author_id = 7 AND title = 'Hello'
# scope.create(title: "Hi")               # author_id 7, status "draft", title "Hi"
# ```
module Grant::Query
  # Converts keyword arguments to a `Grant::ModelArgs` hash with String keys.
  #
  # :nodoc:
  def self.model_args(attrs : NamedTuple) : Grant::ModelArgs
    args = Grant::ModelArgs.new
    attrs.each { |key, value| args[key.to_s] = value }
    args
  end
end

module Grant::Query::Finders(Model)
  # Defaults set with `create_with`. The hash is never mutated once assigned:
  # every write builds a new one, so relations that share it through a copy
  # cannot leak defaults into each other.
  @create_with_defaults : Hash(String, Grant::Columns::Type)?

  # Returns a copy of this relation whose `create`/`build` family starts from
  # *attrs* as extra defaults (merged over earlier `create_with` calls).
  # Passing an empty hash clears them. The receiver is unchanged.
  #
  # ```
  # Post.create_with(status: "draft").create(title: "x").status # => "draft"
  # ```
  def create_with(**attrs : Grant::Columns::Type) : self
    create_with(Grant::Query.model_args(attrs))
  end

  # :ditto:
  def create_with(attrs : Grant::ModelArgs) : self
    chain_copy.create_with!(attrs)
  end

  # In-place `create_with`, for a relation the caller owns.
  def create_with!(attrs : Grant::ModelArgs) : self
    if attrs.empty?
      @create_with_defaults = nil
    else
      merged = Hash(String, Grant::Columns::Type).new
      if existing = @create_with_defaults
        merged.merge!(existing)
      end
      attrs.each { |key, value| merged[key.to_s] = value }
      @create_with_defaults = merged
    end
    self
  end

  # The defaults registered with `create_with`, as a copy.
  def create_with_attributes : Hash(String, Grant::Columns::Type)
    if defaults = @create_with_defaults
      defaults.dup
    else
      Hash(String, Grant::Columns::Type).new
    end
  end

  # The attributes a record built from this relation starts with: the literal
  # equality predicates of the relation (default scope included), keyed by
  # column name. `nil` comparisons and every non-equality predicate are left out.
  #
  # ```
  # Post.where(author_id: 7, published: true).where(:views, :gt, 3).scope_attributes
  # # => {"author_id" => 7, "published" => true}
  # ```
  def scope_attributes : Hash(String, Grant::Columns::Type)
    attrs = Hash(String, Grant::Columns::Type).new
    collect_equality_attributes(default_scope_where_fields, attrs)
    collect_equality_attributes(where_fields, attrs)
    attrs
  end

  private def collect_equality_attributes(fields : Array(Grant::Query::WhereField), into attrs : Hash(String, Grant::Columns::Type)) : Nil
    fields.each do |condition|
      next unless condition.is_a?(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
      next unless condition[:join] == :and && condition[:operator] == :eq

      value = condition[:value]
      next if value.nil?

      if column = own_column_name(condition[:field])
        attrs[column] = value
      end
    end
  end

  # The unquoted column name of *field* when it names a column of `Model`,
  # or `nil` when it is qualified with another table (a joined association's
  # `authors.id` must not seed the model's own `id`) or is not a model column.
  private def own_column_name(field : String) : String?
    unquoted = field.delete('"').delete('`')
    column = unquoted
    if dot = unquoted.rindex('.')
      return unless unquoted[0, dot] == Model.table_name
      column = unquoted[(dot + 1)..]
    end
    Model.fields.includes?(column) ? column : nil
  end

  # Merges *defaults* over this relation's `create_with` defaults in place.
  # Named-scope conversion (`copy_state_to`, `merge_builder`) uses it so a
  # relation rebuilt from another keeps its defaults.
  #
  # :nodoc:
  def adopt_create_with_defaults(defaults : Hash(String, Grant::Columns::Type)) : Nil
    return if defaults.empty?

    merged = Hash(String, Grant::Columns::Type).new
    if existing = @create_with_defaults
      merged.merge!(existing)
    end
    merged.merge!(defaults)
    @create_with_defaults = merged
  end

  # Scope attributes overlaid with `create_with` defaults.
  private def attributes_for_new_record : Hash(String, Grant::Columns::Type)
    attrs = scope_attributes
    if defaults = @create_with_defaults
      attrs.merge!(defaults)
    end
    attrs
  end

  {% for name in %w[build create create! find_or_create_by find_or_create_by! find_or_initialize_by create_or_find_by create_or_find_by! first_or_create first_or_create! first_or_initialize] %}
    # Keyword form; see the relation-level documentation on `Finders`.
    def {{name.id}}(**attrs : Grant::Columns::Type) : Model
      run_{{name.id.gsub(/!$/, "_bang")}}(Grant::Query.model_args(attrs), nil)
    end

    # :ditto:
    def {{name.id}}(**attrs : Grant::Columns::Type, &block : Model ->) : Model
      run_{{name.id.gsub(/!$/, "_bang")}}(Grant::Query.model_args(attrs), block)
    end

    # :ditto:
    def {{name.id}}(attrs : Grant::ModelArgs) : Model
      run_{{name.id.gsub(/!$/, "_bang")}}(attrs, nil)
    end

    # :ditto:
    def {{name.id}}(attrs : Grant::ModelArgs, &block : Model ->) : Model
      run_{{name.id.gsub(/!$/, "_bang")}}(attrs, block)
    end
  {% end %}

  # Alias of `build`, like ActiveRecord's `Relation#new`.
  def new(**attrs : Grant::Columns::Type) : Model
    build(**attrs)
  end

  # :ditto:
  def new(**attrs : Grant::Columns::Type, &block : Model ->) : Model
    build(**attrs, &block)
  end

  # :ditto:
  def new(attrs : Grant::ModelArgs) : Model
    build(attrs)
  end

  # :ditto:
  def new(attrs : Grant::ModelArgs, &block : Model ->) : Model
    build(attrs, &block)
  end

  private def run_build(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    merged = Grant::ModelArgs.new
    attributes_for_new_record.each { |key, value| merged[key] = value }
    attrs.each { |key, value| merged[key.to_s] = value }

    # Model.new(hash) assigns the attributes, then yields, then runs
    # after_initialize, so that callback sees the scope attributes too.
    if callback = block
      Model.new(merged) { |record| callback.call(record) }
    else
      Model.new(merged)
    end
  end

  private def run_create(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    record = run_build(attrs, block)
    record.save
    record
  end

  private def run_create_bang(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    record = run_build(attrs, block)
    record.save!
    record
  end

  private def run_find_or_create_by(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    find_by(attrs) || run_create(attrs, block)
  end

  private def run_find_or_create_by_bang(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    find_by(attrs) || run_create_bang(attrs, block)
  end

  private def run_find_or_initialize_by(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    find_by(attrs) || run_build(attrs, block)
  end

  private def run_first_or_create(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    first || run_create(attrs, block)
  end

  private def run_first_or_create_bang(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    first || run_create_bang(attrs, block)
  end

  private def run_first_or_initialize(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    first || run_build(attrs, block)
  end

  # Inserts inside a savepoint and falls back to a lookup when a unique
  # constraint wins the race, so it needs no prior SELECT. The failed INSERT
  # rolls back to the savepoint, which keeps an enclosing PostgreSQL
  # transaction usable. Validation and other failures behave like `create`.
  private def run_create_or_find_by(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    record = run_build(attrs, block)
    saved = Model.transaction(requires_new: true) { record.save }
    return record if saved
    return record unless record.save_failure_error.statement_error.is_a?(Grant::RecordNotUnique)

    find_by(attrs) || record
  end

  private def run_create_or_find_by_bang(attrs : Grant::ModelArgs, block : Proc(Model, Nil)?) : Model
    record = run_build(attrs, block)
    saved = Model.transaction(requires_new: true) { record.save }
    return record if saved

    failure = record.save_failure_error
    if failure.statement_error.is_a?(Grant::RecordNotUnique)
      find_by!(attrs)
    else
      raise failure
    end
  end

  # Returns the first record matching every column in *criteria* on top of the
  # relation's own conditions, or `nil`. A `nil` value matches `IS NULL`.
  #
  # ```
  # Post.where(published: true).find_by(title: "Hello")
  # ```
  def find_by(**criteria : Grant::Columns::Type) : Model?
    find_by(Grant::Query.model_args(criteria))
  end

  # :ditto:
  def find_by(criteria : Grant::ModelArgs) : Model?
    chain_copy.where!(criteria).first
  end

  # Like `find_by`, raising `Grant::Querying::NotFound` when nothing matches.
  def find_by!(**criteria : Grant::Columns::Type) : Model
    find_by!(Grant::Query.model_args(criteria))
  end

  # :ditto:
  def find_by!(criteria : Grant::ModelArgs) : Model
    find_by(criteria) || raise Grant::Querying::NotFound.new("No #{Model.name} found where #{describe_criteria(criteria)}")
  end

  # The single record matching *criteria*; raises `NotFound` for none and
  # `NotUnique` for several. Reads at most two rows (`LIMIT 2`).
  def find_sole_by(**criteria : Grant::Columns::Type) : Model
    find_sole_by(Grant::Query.model_args(criteria))
  end

  # :ditto:
  def find_sole_by(criteria : Grant::ModelArgs) : Model
    chain_copy.where!(criteria).sole
  end

  private def describe_criteria(criteria : Grant::ModelArgs) : String
    criteria.map { |key, value| value.nil? ? "#{key} is NULL" : "#{key} = #{value}" }.join(" and ")
  end

  # Returns the record with primary key *id* within this relation, or `nil`.
  def find(id : Grant::Querying::IdValue) : Model?
    chain_copy.where!(Model.primary_name, :eq, id).first
  end

  # Returns the records with the given primary keys in *ids* order using one
  # `IN` query. Keys with no record are skipped; see `find!` to raise instead.
  def find(ids : Array) : Array(Model)
    found_records_by_key(ids).first
  end

  # :ditto:
  def find(first : Grant::Querying::IdValue, second : Grant::Querying::IdValue, *rest : Grant::Querying::IdValue) : Array(Model)
    find([first, second, *rest])
  end

  # Like `find(id)`, raising `Grant::Querying::NotFound` when there is no record.
  def find!(id : Grant::Querying::IdValue) : Model
    find(id) || raise Grant::Querying::NotFound.new("Couldn't find #{Model.name} with '#{Model.primary_name}'=#{id}")
  end

  # Like `find(ids)`, but raises `Grant::Querying::NotFound` naming every key
  # that has no record.
  def find!(ids : Array) : Array(Model)
    records, missing = found_records_by_key(ids)
    unless missing.empty?
      raise Grant::Querying::NotFound.new("Couldn't find all #{Model.name} with '#{Model.primary_name}': (#{ids.join(", ")}) (found #{records.size} results, but was looking for #{ids.size}; missing: #{missing.join(", ")})")
    end
    records
  end

  # :ditto:
  def find!(first : Grant::Querying::IdValue, second : Grant::Querying::IdValue, *rest : Grant::Querying::IdValue) : Array(Model)
    find!([first, second, *rest])
  end

  private def found_records_by_key(ids : Array) : {Array(Model), Array(String)}
    return {[] of Model, [] of String} if ids.empty?

    by_key = Hash(String, Model).new
    chain_copy.where!({Model.primary_name => ids}).select.each do |record|
      by_key[record.primary_key_value.to_s] = record
    end

    ordered = [] of Model
    missing = [] of String
    ids.each do |id|
      if record = by_key[id.to_s]?
        ordered << record
      else
        missing << id.to_s
      end
    end
    {ordered, missing}
  end
end
