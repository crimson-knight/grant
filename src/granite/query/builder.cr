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
class Granite::Query::Builder(Model)
  enum DbType
    Mysql
    Sqlite
    Pg
  end

  enum Sort
    Ascending
    Descending
  end

  getter db_type : DbType
  getter where_fields = [] of (NamedTuple(join: Symbol, field: String, operator: Symbol, value: Granite::Columns::Type) |
                               NamedTuple(join: Symbol, stmt: String, value: Granite::Columns::Type))
  getter order_fields = [] of NamedTuple(field: String, direction: Sort)
  getter group_fields = [] of NamedTuple(field: String)
  getter offset : Int64?
  getter limit : Int64?
  getter eager_load_associations = [] of Symbol | Hash(Symbol, Array(Symbol))
  getter preload_associations = [] of Symbol | Hash(Symbol, Array(Symbol))
  getter includes_associations = [] of Symbol | Hash(Symbol, Array(Symbol))

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
      else
        and(field: field.to_s, operator: :eq, value: value)
      end
    end

    self
  end

  def where(field : (Symbol | String), operator : Symbol, value : Granite::Columns::Type)
    and(field: field.to_s, operator: operator, value: value)
  end

  def where(stmt : String, value : Granite::Columns::Type = nil)
    and(stmt: stmt, value: value)
  end

  def and(field : (Symbol | String), operator : Symbol, value : Granite::Columns::Type)
    @where_fields << {join: :and, field: field.to_s, operator: operator, value: value}

    self
  end

  def and(stmt : String, value : Granite::Columns::Type = nil)
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

  def or(field : (Symbol | String), operator : Symbol, value : Granite::Columns::Type)
    @where_fields << {join: :or, field: field.to_s, operator: operator, value: value}

    self
  end

  def or(stmt : String, value : Granite::Columns::Type = nil)
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

  def offset(num)
    @offset = num.to_i64

    self
  end

  def limit(num)
    @limit = num.to_i64

    self
  end

  # Override select to handle eager loading
  def select
    records = assembler.select.run

    # Apply eager loading if any associations are specified
    all_associations = @includes_associations + @preload_associations + @eager_load_associations
    unless all_associations.empty?
      Granite::AssociationLoader.load_associations(records, all_associations)
    end

    records
  end

  def raw_sql
    assembler.select.raw_sql
  end

  def first : Model?
    limit(1).select.first?
  end

  def first! : Model
    first || raise Granite::Querying::NotFound.new("No record found")
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
      raise Granite::Querying::NotFound.new("No record found")
    elsif results.size == 1
      results.first
    else
      raise Granite::Querying::NotUnique.new("Multiple records found (expected exactly one)")
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
  def touch_all(*fields, time : Time = Time.local(Granite.settings.default_timezone)) : Int64
    Model.mark_write_operation
    assembler.touch_all(fields, time: time)
  end

  def count
    assembler.count
  end

  def exists? : Bool
    assembler.exists?.run
  end

  def size
    count
  end

  def reject(&)
    assembler.select.run.reject do |record|
      yield record
    end
  end

  def each(&)
    assembler.select.tap do |record_set|
      record_set.each do |record|
        yield record
      end
    end
  end

  def map(&)
    assembler.select.run.map do |record|
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

  # Create a new query builder for OR conditions
  def or(&)
    or_builder = self.class.new(@db_type, :or)
    yield or_builder

    # Add the OR conditions as a group
    if or_builder.where_fields.any?
      @where_fields << {
        join:  :and,
        stmt:  "(#{or_builder.assembler.where_clause(or_builder.where_fields)})",
        value: nil,
      }
    end

    self
  end

  # Support for not conditions
  def not(&)
    not_builder = self.class.new(@db_type)
    yield not_builder

    # Add the NOT conditions as a negated group
    if not_builder.where_fields.any?
      @where_fields << {
        join:  :and,
        stmt:  "NOT (#{not_builder.assembler.where_clause(not_builder.where_fields)})",
        value: nil,
      }
    end

    self
  end
end
