class Grant::AssociationCollection(Owner, Target)
  forward_missing_to all

  def initialize(@owner : Owner, @foreign_key : (Symbol | String), @through : (Symbol | String | Nil) = nil, @primary_key : (Symbol | String | Nil) = nil)
  end

  def all(clause = "", params = [] of DB::Any)
    start_time = Time.monotonic
    results = Target.all(
      [query, clause].join(" "),
      [owner.primary_key_value] + params
    )
    duration = Time.monotonic - start_time
    
    Grant::Logs::Association.info { "Loaded has_many association - #{Owner.name} [#{Target.name}] [fk: #{@foreign_key}] - #{results.size} records (#{duration.total_milliseconds}ms)" }
    
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

  private getter owner
  private getter foreign_key
  private getter through

  private def query
    if through.nil?
      "WHERE #{Target.table_name}.#{@foreign_key} = ?"
    else
      key = @primary_key || "#{Target.to_s.underscore}_id"
      "JOIN #{through} ON #{through}.#{key} = #{Target.table_name}.#{Target.primary_name} " \
      "WHERE #{through}.#{@foreign_key} = ?"
    end
  end
end
