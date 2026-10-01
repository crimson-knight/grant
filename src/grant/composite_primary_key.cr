require "./composite_primary_key/transactions"
require "./composite_primary_key/validation"

# Composite primary keys and `query_constraints`.
#
# A model with a composite primary key declares every key column with
# `primary: true` and names the tuple once:
#
# ```
# class OrderItem < Grant::Base
#   include Grant::CompositePrimaryKey
#   column shop_id : Int64, primary: true
#   column order_id : Int64, primary: true
#   column quantity : Int32
#   composite_primary_key shop_id, order_id
# end
#
# OrderItem.find({1_i64, 2_i64})                    # one row, by key tuple
# OrderItem.find({shop_id: 1_i64, order_id: 2_i64}) # same, by name
# OrderItem.find([{1_i64, 2_i64}, {1_i64, 3_i64}])  # rows, one row-value IN query
# ```
#
# `query_constraints` keeps a single-column primary key but makes every
# persistence statement (find by tuple, update, destroy, delete, reload, touch,
# update_columns, increment!) carry extra columns in its WHERE, such as a
# tenant or shard key:
#
# ```
# class Invoice < Grant::Base
#   column id : Int64, primary: true
#   column tenant_id : Int64
#   query_constraints :tenant_id, :id
# end
# ```
#
# Composite and constrained models override the persistence methods of
# `Grant::Transactions` (see `Grant::CompositePrimaryKey::Transactions`). A
# model without either declaration keeps the single-key code path untouched.
module Grant::CompositePrimaryKey
  # Stores composite primary key configuration
  struct CompositeKey
    property columns : Array(Symbol)

    def initialize(@columns : Array(Symbol))
      raise "Composite key must have at least 2 columns" if @columns.size < 2
    end

    # Generate a unique key string from values
    def key_for(values : Array) : String
      raise "Values count (#{values.size}) doesn't match columns count (#{@columns.size})" if values.size != @columns.size

      @columns.zip(values).map { |col, val| "#{col}=#{val}" }.join(":")
    end

    # Extract values from a model instance
    def values_for(model : Grant::Base) : Array
      @columns.map { |col| model.read_attribute(col.to_s) }
    end

    # Build WHERE clause for composite key
    def where_clause : String
      @columns.map { |col| "#{col} = ?" }.join(" AND ")
    end

    # Build named tuple from hash/named tuple input
    def build_key_tuple(**values) : NamedTuple
      # Verify all key columns are present
      @columns.each do |col|
        raise "Missing composite key column: #{col}" unless values.has_key?(col)
      end

      values
    end
  end

  macro included
    include Grant::CompositePrimaryKey::Transactions
    include Grant::CompositePrimaryKey::Validation

    class_property composite_key : CompositeKey?

    # Lets code that only holds the class name (joins over a composite
    # association) read this model's key columns.
    Grant::CompositeAssociation.register_key_columns({{@type.name.stringify}}, -> { {{@type}}.persistence_key_columns })

    # Columns named by `query_constraints`, in declaration order.
    class_property query_constraint_names : Array(String)?

    # Override primary_name to handle composite keys
    def self.primary_name
      if ck = composite_key
        # Return first column for backward compatibility
        ck.columns.first.to_s
      else
        super
      end
    end

    # Check if model uses composite primary key
    def self.composite_primary_key? : Bool
      !composite_key.nil?
    end

    # Get all primary key columns when using composite key DSL
    def self.composite_primary_key_columns : Array(Symbol)
      composite_key.try(&.columns) || [] of Symbol
    end

    # True when `query_constraints` names the columns that scope a record.
    def self.query_constrained? : Bool
      !query_constraint_names.nil?
    end

    # The columns that identify one row in every persistence statement and in
    # `find` by tuple: the `query_constraints` columns, else the composite
    # primary key columns, else the single primary key.
    def self.persistence_key_columns : Array(String)
      if names = query_constraint_names
        names
      elsif ck = composite_key
        ck.columns.map(&.to_s)
      else
        [primary_name]
      end
    end

    # True when a record of this model is written through its key tuple (a
    # composite primary key or `query_constraints`) rather than through one
    # primary key column.
    def self.keyed_by_tuple? : Bool
      composite_primary_key? || query_constrained?
    end

    # True when *column* is a primary key column declared `auto: true`: the
    # database (or Grant, for UUIDs) fills it in on insert.
    def self.__auto_generated_key_column?(column : String) : Bool
      \{% begin %}
        \{% for ivar in @type.instance_vars.select { |iv| (ann = iv.annotation(Grant::Column)) && ann[:primary] && ann[:auto] == true } %}
          return true if column == \{{ivar.name.stringify}}
        \{% end %}
        false
      \{% end %}
    end

    # Relation behind the tuple finders: the model's default scope.
    def self.__key_relation
      current_scope
    end

    # Returns the row whose key columns equal *key* (a `Tuple` in
    # `persistence_key_columns` order), or `nil`.
    def self.find(key : Tuple) : self?
      __key_relation.where_key(key).first
    end

    # Returns the row whose key columns equal *key* (a `NamedTuple` naming every
    # key column), or `nil`.
    def self.find(key : NamedTuple) : self?
      __key_relation.where_key(key).first
    end

    # Keyword form of `find(NamedTuple)`: `Model.find(shop_id: 1, id: 2)`.
    def self.find(**keys) : self?
      find(keys)
    end

    # Returns the rows matching any of *keys*, in *keys* order, with one
    # row-value `IN` query per `Grant.settings.in_clause_limit` tuples. Missing
    # keys are skipped; see `find!` to raise instead.
    def self.find(keys : Array(Tuple)) : Array(self)
      __key_relation.find_keys(keys)
    end

    # Like `find(key)`, raising `Grant::Querying::NotFound` when there is no row.
    def self.find!(key : Tuple) : self
      find(key) || raise Grant::Querying::NotFound.new("No #{name} found with key #{persistence_key_columns.join(", ")} = #{key.to_a.join(", ")}")
    end

    # :ditto:
    def self.find!(key : NamedTuple) : self
      find(key) || raise Grant::Querying::NotFound.new("No #{name} found with keys: #{key}")
    end

    # :ditto:
    def self.find!(**keys) : self
      find!(keys)
    end

    # Like `find(keys)`, raising `Grant::Querying::NotFound` naming every
    # missing key.
    def self.find!(keys : Array(Tuple)) : Array(self)
      __key_relation.find_keys!(keys)
    end

    # True when a row with this key exists.
    def self.exists?(key : Tuple) : Bool
      __key_relation.where_key(key).exists?
    end

    # :ditto:
    def self.exists?(key : NamedTuple) : Bool
      __key_relation.where_key(key).exists?
    end

    # :ditto:
    def self.exists?(**keys) : Bool
      exists?(keys)
    end
  end

  # DSL for defining composite primary keys
  macro composite_primary_key(*columns)
    # Simply store the composite key configuration
    # Validation will happen at runtime when CompositeKey is initialized
    self.composite_key = Grant::CompositePrimaryKey::CompositeKey.new(
      [{% for col in columns %}:{{col.id}}, {% end %}] of Symbol
    )

  end

  # Instance methods

  # Get composite key values as hash
  def composite_key_values
    return nil unless self.class.composite_primary_key?

    ck = self.class.composite_key.not_nil!
    values = {} of Symbol => Grant::Columns::Type

    ck.columns.each do |col|
      values[col] = read_attribute(col.to_s)
    end

    values
  end

  # The key tuple, as ActiveRecord's `id` of a composite primary key (nil while
  # a part is unset). A model with a column named `id` keeps its own reader.
  def id : Array(Grant::Columns::Type)?
    to_key
  end

  # The values of the record's key columns (`persistence_key_columns`), in
  # that order. A column whose value is unset is `nil`.
  def key_tuple_values : Array(Grant::Columns::Type)
    self.class.persistence_key_columns.map { |column| read_attribute(column) }
  end
end

abstract class Grant::Base
  # Scopes every persistence statement of a record by *columns* in addition to
  # its primary key: `query_constraints :tenant_id, :id` makes update, destroy,
  # delete, reload, touch, update_columns and increment! write
  # `WHERE tenant_id = ? AND id = ?`, and `Model.find({tenant, id})` read it.
  # Mirrors ActiveRecord's `query_constraints`.
  macro query_constraints(*columns)
    include Grant::CompositePrimaryKey

    self.query_constraint_names = [{% for column in columns %}{{column.id.stringify}}, {% end %}] of String
  end
end
