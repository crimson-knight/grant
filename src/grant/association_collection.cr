# The lazy collection returned by a `has_many` association (e.g. `user.posts`).
#
# It is **not** loaded until you call a terminal method. Any method it doesn't
# define is forwarded (via `forward_missing_to all`) to the loaded
# `Array(Target)`, so standard `Enumerable`/`Array` methods (`map`, `select`,
# `each`, `size`, `to_a`, ...) work directly. On top of that it provides
# scoped finders (`find`, `find_by`, `find_by!`), builders (`build`, `create`,
# `create!`) that pre-set the foreign key to the owner, and bulk removal
# (`destroy_all`, `delete_all`).
#
# ```
# user = User.find!(1)
# user.posts.to_a # loads and returns Array(Post)
# user.posts.size # forwarded to the loaded array
# user.posts.where(published: true).to_a
# user.posts.find_by(title: "Hello") # => Post? scoped to this user
# user.posts.create(title: "New")    # builds + saves with user_id pre-set
# user.posts.destroy_all             # destroy each child (runs callbacks)
# ```
class Grant::AssociationCollection(Owner, Target)
  forward_missing_to all

  # `@scope` carries an optional association-scope lambda (the `-> { ... }` form
  # of `has_many :posts, -> { where(published: true) }`). When present it is
  # applied to a fresh `Target` query builder and the resulting WHERE fragment is
  # merged into the association query so the collection is filtered by the scope.
  def initialize(@owner : Owner, @foreign_key : (Symbol | String), @through : (Symbol | String | Nil) = nil, @primary_key : (Symbol | String | Nil) = nil, @inverse_of : (Symbol | String | Nil) = nil, @scope : (Grant::Query::Builder(Target) -> Grant::Query::Builder(Target))? = nil)
  end

  # Loads and returns the associated records as an `Array(Target)`, applying any
  # association scope. An optional raw SQL *clause* (with `?` placeholders) and
  # its *params* are AND-appended to the association's WHERE.
  #
  # ```
  # user.posts.all                                # => Array(Post)
  # user.posts.all("posts.published = ?", [true]) # extra raw filter
  # ```
  def all(clause = "", params = [] of DB::Any)
    start_time = Time.monotonic
    scope_clause, scope_params = scope_fragment
    all_params = [owner.primary_key_value.as(Grant::Columns::Type)]
    scope_params.each { |p| all_params << p }
    params.each { |p| all_params << p.as(Grant::Columns::Type) }
    results = Target.all(
      [query, scope_clause, clause].reject(&.empty?).join(" "),
      all_params
    )
    duration = Time.monotonic - start_time

    Grant::Logs::Association.info { "Loaded has_many association - #{Owner.name} [#{Target.name}] [fk: #{@foreign_key}] - #{results.size} records (#{duration.total_milliseconds}ms)" }

    # Set inverse association on loaded records to prevent N+1 queries
    if inv = @inverse_of
      results.each do |record|
        record.set_loaded_association(inv.to_s, owner)
      end
    end

    results
  end

  # Returns the first associated record matching *args* (column => value), or
  # `nil`. The match is constrained to this owner's collection.
  #
  # ```
  # user.posts.find_by(title: "Hello") # => Post? belonging to this user
  # ```
  def find_by(**args)
    start_time = Time.monotonic
    result = Target.first(
      "#{query} AND #{args.map { |arg| "#{Target.quote(Target.table_name)}.#{Target.quote(arg.to_s)} = ?" }.join(" AND ")}",
      [owner.primary_key_value] + args.values.to_a
    )
    duration = Time.monotonic - start_time

    if result
      Grant::Logs::Association.debug { "Found record in association - #{Owner.name} [#{Target.name}] [fk: #{@foreign_key}] (#{duration.total_milliseconds}ms) - #{args.to_h}" }
      # Set inverse association on found record
      if inv = @inverse_of
        result.set_loaded_association(inv.to_s, owner)
      end
    end

    result
  end

  # Like `find_by`, but raises `Grant::Querying::NotFound` when no record in the
  # collection matches *args*.
  #
  # ```
  # user.posts.find_by!(title: "Hello") # => Post (raises if absent)
  # ```
  def find_by!(**args)
    find_by(**args) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{args.map { |k, v| "#{k} = #{v}" }.join(" and ")}")
  end

  # Finds a `Target` by primary key *value*, or `nil`. Note this delegates to
  # `Target.find` and is **not** constrained to the collection.
  #
  # ```
  # user.posts.find(1) # => Post? with id 1
  # ```
  def find(value)
    Target.find(value)
  end

  # Finds a `Target` by primary key *value*, raising
  # `Grant::Querying::NotFound` when absent. Delegates to `Target.find!` and is
  # **not** constrained to the collection.
  #
  # ```
  # user.posts.find!(1) # => Post with id 1 (raises if absent)
  # ```
  def find!(value)
    Target.find!(value)
  end

  # Builds a new Target instance with the foreign key pre-set to the
  # owner's primary key. The record is NOT saved to the database.
  #
  # ```
  # post = author.posts.build(title: "New Post")
  # post.author_id   # => author.id
  # post.new_record? # => true
  # ```
  def build(**attrs) : Target
    record = Target.new
    record.set_attributes(attrs.to_h.transform_keys(&.to_s))
    # Set foreign key to owner's primary key
    record.set_attributes({@foreign_key.to_s => owner.primary_key_value})
    record
  end

  # Builds and saves a new Target instance with the foreign key pre-set.
  # Returns the record (which may have errors if save failed).
  #
  # ```
  # post = author.posts.create(title: "New Post")
  # post.persisted? # => true (if valid)
  # ```
  def create(**attrs) : Target
    record = build(**attrs)
    record.save
    record
  end

  # Builds and saves a new Target instance. Raises
  # `Grant::RecordNotSaved` if the save fails.
  #
  # ```
  # post = author.posts.create!(title: "New Post") # raises if invalid
  # ```
  def create!(**attrs) : Target
    record = build(**attrs)
    record.save!
    record
  end

  # Destroys all associated records by loading each and calling destroy.
  # This triggers callbacks on each record.
  #
  # Returns the number of records destroyed.
  def destroy_all : Int32
    records = all
    count = 0
    records.each do |record|
      if record.destroy
        count += 1
      end
    end
    count
  end

  # Deletes all associated records using a single SQL DELETE.
  # Does NOT instantiate records or run callbacks.
  #
  # Returns the number of rows deleted.
  def delete_all : Int64
    Target.where("#{Target.table_name}.#{@foreign_key} = ?", owner.primary_key_value).delete_all
  end

  private getter owner
  private getter foreign_key
  private getter through

  # Maps Query::Builder operator symbols to SQL operators for raw fragment
  # generation. Mirrors `Grant::Query::Assembler::Base::OPERATORS`.
  SCOPE_OPERATORS = {"eq" => "=", "gteq" => ">=", "lteq" => "<=", "neq" => "!=", "ltgt" => "<>", "gt" => ">", "lt" => "<", "ngt" => "!>", "nlt" => "!<", "like" => "LIKE", "nlike" => "NOT LIKE"}

  # Evaluates the association scope lambda (if any) against a fresh `Target`
  # query builder and translates its accumulated WHERE conditions into a raw
  # SQL fragment (prefixed with `AND`) plus an ordered parameter array. The
  # fragment uses `?` placeholders, which `Target.all` rewrites per-adapter.
  #
  # Only simple field/operator/value and raw-statement conditions are
  # translated — this covers the common `-> { where(...) }` association-scope
  # forms. The fragment is qualified with the target table name so it composes
  # correctly with the JOIN used by `:through` associations.
  private def scope_fragment : Tuple(String, Array(Grant::Columns::Type))
    scope = @scope
    return {"", [] of Grant::Columns::Type} unless scope

    db_type = case Target.adapter.class.to_s
              when "Grant::Adapter::Pg"    then Grant::Query::Builder::DbType::Pg
              when "Grant::Adapter::Mysql" then Grant::Query::Builder::DbType::Mysql
              else                              Grant::Query::Builder::DbType::Sqlite
              end
    builder = scope.call(Grant::Query::Builder(Target).new(db_type))
    clauses = [] of String
    params = [] of Grant::Columns::Type

    builder.where_fields.each do |field|
      if field.is_a?(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
        op = SCOPE_OPERATORS[field[:operator].to_s]? || field[:operator].to_s
        col = field[:field]
        col = "#{Target.quote(Target.table_name)}.#{Target.quote(col)}" unless col.includes?(".")
        clauses << "#{col} #{op} ?"
        params << field[:value]
      elsif field.is_a?(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))
        clauses << "(#{field[:stmt]})"
        params << field[:value] unless field[:value].nil?
      end
    end

    return {"", [] of Grant::Columns::Type} if clauses.empty?
    {"AND #{clauses.join(" AND ")}", params}
  end

  private def query
    if through.nil?
      "WHERE #{Target.table_name}.#{@foreign_key} = ?"
    else
      # For :through associations, the join key is the foreign key on the join table
      # that references the Target's primary key. If a custom primary_key was provided
      # (and it's not the default "id"), use it; otherwise derive from Target class name.
      key = if @primary_key && @primary_key != "id"
              @primary_key
            else
              "#{Target.to_s.underscore}_id"
            end
      "JOIN #{through} ON #{through}.#{key} = #{Target.table_name}.#{Target.primary_name} " \
      "WHERE #{through}.#{@foreign_key} = ?"
    end
  end
end
