require "../columns"
require "../async"
require "./where_chain"

# Data structure which will allow chaining of query components,
# nesting of boolean logic, etc.
#
# Should return self, or another instance of Builder wherever
# chaining should be possible.
#
# Current query syntax:
# - where(field: value) => "WHERE field = 'value'"
#
# Hopefully soon:
# - Model.where(field: value).not( Model.where(field2: value2) )
# or
# - Model.where(field: value).not { where(field2: value2) }
#
# - Model.where(field: value).or( Model.where(field3: value3) )
# or
# - Model.where(field: value).or { whehre(field3: value3) }
class Grant::Query::Builder(Model)
  include Grant::Async::QueryMethods(Model)
  include Enumerable(Model)

  enum DbType
    Mysql
    Sqlite
    Pg
  end

  enum Sort
    Ascending
    Descending
  end

  alias WhereField = NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type) |
                     NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type)
  alias AssociationQuery = Symbol | Hash(Symbol, Array(Symbol))
  
  getter db_type : DbType
  getter where_fields : Array(WhereField) = [] of WhereField
  getter order_fields = [] of NamedTuple(field: String, direction: Sort)
  getter group_fields = [] of NamedTuple(field: String)
  getter offset : Int64?
  getter limit : Int64?
  getter eager_load_associations : Array(AssociationQuery) = [] of AssociationQuery
  getter preload_associations : Array(AssociationQuery) = [] of AssociationQuery
  getter includes_associations : Array(AssociationQuery) = [] of AssociationQuery
  getter lock_mode : Grant::Locking::LockMode?
  getter select_columns : Array(String)?

  def initialize(@db_type, @boolean_operator = :and)
  end

  def assembler : Assembler::Base(Model)
    case @db_type
    when DbType::Pg
      Assembler::Pg(Model).new self
    when DbType::Mysql
      Assembler::Mysql(Model).new self
    when DbType::Sqlite
      Assembler::Sqlite(Model).new self
    else
      raise "Unknown database type: #{@db_type}"
    end
  end

  def where(**matches)
    where(matches)
  end

  def where(matches)
    matches.each do |field, value|
      if value.is_a?(Array)
        and(field: field.to_s, operator: :in, value: value.compact)
      elsif value.is_a?(Enum)
        and(field: field.to_s, operator: :eq, value: value.to_s)
      elsif value.is_a?(Range)
        # Handle range as BETWEEN operation
        and(field: field.to_s, operator: :gteq, value: value.begin)
        and(field: field.to_s, operator: :lteq, value: value.end)
      elsif value.is_a?(Builder)
        # Handle subquery
        and_subquery(field: field.to_s, subquery: value)
      else
        and(field: field.to_s, operator: :eq, value: value)
      end
    end

    self
  end

  def where(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type)
    and(field: field.to_s, operator: operator, value: value)
  end

  def where(stmt : String, value : Grant::Columns::Type = nil)
    and(stmt: stmt, value: value)
  end

  # Returns a WhereChain for advanced where methods.
  #
  # Example:
  # ```
  # User.where.like(:email, "%@gmail.com")
  #     .where.gt(:age, 18)
  #     .where.not_in(:status, ["banned", "suspended"])
  # ```
  def where : WhereChain(Model)
    WhereChain(Model).new(self)
  end

  def and(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type)
    @where_fields << {join: :and, field: field.to_s, operator: operator, value: value}

    self
  end

  def and(stmt : String, value : Grant::Columns::Type = nil)
    @where_fields << {join: :and, stmt: stmt, value: value}

    self
  end

  def and(**matches)
    and(matches)
  end

  def and(matches)
    matches.each do |field, value|
      if value.is_a?(Array)
        and(field: field.to_s, operator: :in, value: value.compact)
      elsif value.is_a?(Enum)
        and(field: field.to_s, operator: :eq, value: value.to_s)
      elsif value.is_a?(Range)
        # Handle range as BETWEEN operation
        and(field: field.to_s, operator: :gteq, value: value.begin)
        and(field: field.to_s, operator: :lteq, value: value.end)
      else
        and(field: field.to_s, operator: :eq, value: value)
      end
    end
    self
  end

  def or(**matches)
    or(matches)
  end

  def or(matches)
    matches.each do |field, value|
      if value.is_a?(Array)
        or(field: field.to_s, operator: :in, value: value.compact)
      elsif value.is_a?(Enum)
        or(field: field.to_s, operator: :eq, value: value.to_s)
      elsif value.is_a?(Range)
        # Handle range as BETWEEN operation - for OR, we need to group these
        or(field: field.to_s, operator: :gteq, value: value.begin)
        or(field: field.to_s, operator: :lteq, value: value.end)
      else
        or(field: field.to_s, operator: :eq, value: value)
      end
    end
    self
  end

  def or(field : (Symbol | String), operator : Symbol, value : Grant::Columns::Type)
    @where_fields << {join: :or, field: field.to_s, operator: operator, value: value}

    self
  end

  def or(stmt : String, value : Grant::Columns::Type = nil)
    @where_fields << {join: :or, stmt: stmt, value: value}

    self
  end

  def order(field : Symbol)
    @order_fields << {field: field.to_s, direction: Sort::Ascending}

    self
  end

  def order(fields : Array(Symbol))
    fields.each do |field|
      order field
    end

    self
  end

  def order(**dsl)
    order(dsl)
  end

  def order(dsl)
    dsl.each do |field, dsl_direction|
      direction = Sort::Ascending

      if dsl_direction == "desc" || dsl_direction == :desc
        direction = Sort::Descending
      end

      @order_fields << {field: field.to_s, direction: direction}
    end

    self
  end

  def group_by(field : Symbol)
    @group_fields << {field: field.to_s}

    self
  end

  def group_by(fields : Array(Symbol))
    fields.each do |field|
      group_by field
    end

    self
  end

  def group_by(**dsl)
    group_by(dsl)
  end

  def group_by(dsl)
    dsl.each do |field, _|
      @group_fields << {field: field.to_s}
    end

    self
  end

  def lock(mode : Grant::Locking::LockMode = Grant::Locking::LockMode::Update)
    @lock_mode = mode
    self
  end

  def offset(num)
    @offset = num.nil? ? nil : num.to_i64

    self
  end

  def limit(num)
    @limit = num.nil? ? nil : num.to_i64

    self
  end

  # Override select to handle eager loading
  def select
    records = assembler.select.run

    # Apply eager loading if any associations are specified
    all_associations = @includes_associations + @preload_associations + @eager_load_associations
    unless all_associations.empty?
      Grant::AssociationLoader.load_associations(records, all_associations)
    end

    records
  end

  def all
    self.select
  end

  def raw_sql
    assembler.select.raw_sql
  end

  def first : Model?
    limit(1).select.first?
  end

  def first! : Model
    first || raise Grant::Querying::NotFound.new("No record found")
  end

  def first(n : Int32) : Array(Model)
    limit(n).select
  end

  def any? : Bool
    !first.nil?
  end

  # Returns the single record. Raises `NotFound` if no record found.
  # Raises `NotUnique` if more than one record found.
  def sole : Model
    results = self.select

    if results.size == 0
      raise Grant::Querying::NotFound.new("No record found")
    elsif results.size == 1
      results.first
    else
      raise Grant::Querying::NotUnique.new("Multiple records found (expected exactly one)")
    end
  end

  # Finds and destroys all records matching the query
  def destroy_all : Int32
    records = self.select
    count = 0
    records.each do |record|
      if record.destroy
        count += 1
      end
    end
    count
  end

  def delete
    Model.mark_write_operation
    assembler.delete
  end

  # Updates updated_at timestamp for all matching records
  def touch_all(*fields, time : Time = Time.local(Grant.settings.default_timezone)) : Int64
    Model.mark_write_operation
    assembler.touch_all(fields, time: time)
  end

  def count : Int64
    result = assembler.count.run
    case result
    when Int64
      result
    when Array(Int64)
      result.sum
    else
      0_i64
    end
  end

  def exists? : Bool
    assembler.exists?.run
  end

  def size
    count
  end

  def each(& : Model ->) : Nil
    self.select.each do |record|
      yield record
    end
  end

  # Eager loading methods
  def includes(*associations)
    associations.each do |assoc|
      @includes_associations << assoc
    end
    self
  end

  def includes(**nested_associations)
    nested_associations.each do |name, nested|
      @includes_associations << {name => nested.is_a?(Array) ? nested : [nested]}
    end
    self
  end

  def preload(*associations)
    associations.each do |assoc|
      @preload_associations << assoc
    end
    self
  end

  def preload(**nested_associations)
    nested_associations.each do |name, nested|
      @preload_associations << {name => nested.is_a?(Array) ? nested : [nested]}
    end
    self
  end

  def eager_load(*associations)
    associations.each do |assoc|
      @eager_load_associations << assoc
    end
    self
  end

  def eager_load(**nested_associations)
    nested_associations.each do |name, nested|
      @eager_load_associations << {name => nested.is_a?(Array) ? nested : [nested]}
    end
    self
  end

  # Create a new query builder for OR conditions.
  #
  # Example:
  # ```
  # User.where(active: true)
  #     .or { |q| q.where(role: "admin") }
  #     .or { |q| q.where.gt(:level, 10) }
  # # SQL: WHERE active = true OR (role = 'admin') OR (level > 10)
  # ```
  def or(&)
    or_builder = self.class.new(@db_type, :or)
    yield or_builder

    # Add the OR conditions as a group
    if or_builder.where_fields.any?
      # Build the OR clause directly without creating assembler
      or_clauses = or_builder.where_fields.map_with_index do |field, idx|
        stmt = case field
               when NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type)
                 field[:stmt]
               when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
                 # Simple operator to SQL mapping for OR clauses
                 case field[:operator]
                 when :eq then "#{field[:field]} = ?"
                 when :neq then "#{field[:field]} != ?"
                 when :gt then "#{field[:field]} > ?"
                 when :lt then "#{field[:field]} < ?"
                 when :gteq then "#{field[:field]} >= ?"
                 when :lteq then "#{field[:field]} <= ?"
                 when :in then "#{field[:field]} IN (?)"
                 when :nin then "#{field[:field]} NOT IN (?)"
                 when :like then "#{field[:field]} LIKE ?"
                 when :nlike then "#{field[:field]} NOT LIKE ?"
                 else
                   raise "Unsupported operator in OR clause: #{field[:operator]}"
                 end
               else
                 raise "Unknown where field type"
               end
        
        if idx == 0
          stmt
        else
          "OR #{stmt}"
        end
      end.join(" ")
      
      @where_fields << {
        join:  :and,
        stmt:  "(#{or_clauses})",
        value: nil,
      }
    end

    self
  end

  # Support for NOT conditions - negates a group of conditions.
  #
  # Example:
  # ```
  # User.not { |q| q.where(status: "banned").where(active: false) }
  # # SQL: WHERE NOT (status = 'banned' AND active = false)
  # ```
  def not(&)
    not_builder = self.class.new(@db_type)
    yield not_builder

    # Add the NOT conditions as a negated group
    if not_builder.where_fields.any?
      # Build the NOT clause directly without creating assembler
      not_clauses = not_builder.where_fields.map_with_index do |field, idx|
        stmt = case field
               when NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type)
                 field[:stmt]
               when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type)
                 # Simple operator to SQL mapping for NOT clauses
                 case field[:operator]
                 when :eq then "#{field[:field]} = ?"
                 when :neq then "#{field[:field]} != ?"
                 when :gt then "#{field[:field]} > ?"
                 when :lt then "#{field[:field]} < ?"
                 when :gteq then "#{field[:field]} >= ?"
                 when :lteq then "#{field[:field]} <= ?"
                 when :in then "#{field[:field]} IN (?)"
                 when :nin then "#{field[:field]} NOT IN (?)"
                 when :like then "#{field[:field]} LIKE ?"
                 when :nlike then "#{field[:field]} NOT LIKE ?"
                 else
                   raise "Unsupported operator in NOT clause: #{field[:operator]}"
                 end
               else
                 raise "Unknown where field type"
               end
        
        if idx == 0
          stmt
        else
          "AND #{stmt}"
        end
      end.join(" ")
      
      @where_fields << {
        join:  :and,
        stmt:  "NOT (#{not_clauses})",
        value: nil,
      }
    end

    self
  end
  
  # Delete all records matching the query
  def delete_all : Int64
    result = assembler.delete
    result.rows_affected
  end

  # Merge another query's conditions into this one.
  #
  # Combines WHERE conditions with AND, and takes the merged query's
  # ORDER BY, LIMIT, and OFFSET if they are set.
  #
  # Example:
  # ```
  # active = User.where(active: true)
  # admins = User.where(role: "admin")
  # active_admins = active.merge(admins)
  # # WHERE active = true AND role = 'admin'
  # ```
  def merge(other : self) : self
    # Merge where conditions
    other.where_fields.each do |field|
      @where_fields << field
    end
    
    # Merge order fields (other's order takes precedence if both have orders)
    if other.order_fields.any?
      @order_fields = other.order_fields
    end
    
    # Merge group fields
    other.group_fields.each do |field|
      @group_fields << field unless @group_fields.includes?(field)
    end
    
    # Use other's limit/offset if set
    @limit = other.limit if other.limit
    @offset = other.offset if other.offset
    
    # Merge associations
    @eager_load_associations.concat(other.eager_load_associations).uniq!
    @preload_associations.concat(other.preload_associations).uniq!
    @includes_associations.concat(other.includes_associations).uniq!
    
    # Use other's lock mode if set
    @lock_mode = other.lock_mode if other.lock_mode
    
    self
  end

  # Create a copy of this query.
  #
  # Useful for creating query variations without modifying the original.
  #
  # Example:
  # ```
  # base_query = User.where(active: true).order(name: :asc)
  # admins = base_query.dup.where(role: "admin")
  # recent = base_query.dup.where.gteq(:created_at, 7.days.ago)
  # ```
  def dup : self
    new_query = self.class.new(@db_type, @boolean_operator)
    
    # Copy all fields
    @where_fields.each { |f| new_query.where_fields << f }
    @order_fields.each { |f| new_query.order_fields << f }
    @group_fields.each { |f| new_query.group_fields << f }
    
    new_query.limit(@limit) if @limit
    new_query.offset(@offset) if @offset
    
    @eager_load_associations.each { |a| new_query.eager_load_associations << a }
    @preload_associations.each { |a| new_query.preload_associations << a }
    @includes_associations.each { |a| new_query.includes_associations << a }
    
    if lock_mode = @lock_mode
      new_query.lock(lock_mode)
    end
    
    new_query
  end

  # Add a subquery condition
  private def and_subquery(field : String, subquery : Builder)
    sql = subquery.assembler.select.raw_sql
    @where_fields << {join: :and, stmt: "#{field} IN (#{sql})", value: nil}
    self
  end

  # Select only specific columns (for subqueries).
  #
  # Useful for IN subqueries where you only need IDs.
  #
  # Example:
  # ```
  # admin_ids = User.where(role: "admin").select(:id)
  # Post.where(user_id: admin_ids)
  # ```
  def select(*columns : Symbol)
    # This would need to be implemented in the assembler
    # For now, we'll store the columns for later use
    @select_columns = columns.map(&.to_s).to_a
    self
  end
end
