class Grant::AssociationCollection(Owner, Target)
  forward_missing_to all

  def initialize(@owner : Owner, @foreign_key : (Symbol | String), @through : (Symbol | String | Nil) = nil, @primary_key : (Symbol | String | Nil) = nil, @inverse_of : (Symbol | String | Nil) = nil)
  end

  def all(clause = "", params = [] of DB::Any)
    start_time = Time.monotonic
    results = Target.all(
      [query, clause].join(" "),
      [owner.primary_key_value] + params
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

  def find_by!(**args)
    find_by(**args) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{args.map { |k, v| "#{k} = #{v}" }.join(" and ")}")
  end

  def find(value)
    Target.find(value)
  end

  def find!(value)
    Target.find!(value)
  end

  # Builds a new Target instance with the foreign key pre-set to the
  # owner's primary key. The record is NOT saved to the database.
  #
  # ```
  # post = author.posts.build(title: "New Post")
  # post.author_id # => author.id
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
