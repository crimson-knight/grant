require "json"
require "../../adapter/base"
require "./column_info"

module Grant::Schema
  # Raised when a schema question names a table the database does not have.
  class TableNotFound < Grant::ErrorBase
    getter table_name : String

    def initialize(@table_name : String)
      super("Table '#{@table_name}' does not exist")
    end
  end

  # Raised when an adapter has no catalog queries.
  class IntrospectionNotSupported < Grant::ErrorBase
    def initialize(adapter_name : String)
      super("Schema introspection is not supported by the #{adapter_name} adapter")
    end
  end

  # Raised when a dumped schema cache file cannot be used.
  class CacheFileError < Grant::ErrorBase
  end

  # The on-disk shape of a dumped schema cache.
  struct CacheFile
    include JSON::Serializable

    getter version : Int32
    getter adapter : String
    getter tables : Array(String)
    getter columns : Array(ColumnInfo)
    getter indexes : Array(IndexInfo)
    getter foreign_keys : Array(ForeignKeyInfo)

    def initialize(@version : Int32, @adapter : String, @tables : Array(String),
                   @columns : Array(ColumnInfo), @indexes : Array(IndexInfo),
                   @foreign_keys : Array(ForeignKeyInfo))
    end
  end

  # Rows of one catalog kind, grouped by table. The first read loads every
  # table with one query; `reset(table)` only marks that table stale so the next
  # read re-queries just that table.
  # :nodoc:
  class Bucket(T)
    @entries : Hash(String, Array(T))? = nil
    @stale = Set(String).new

    def loaded? : Bool
      !@entries.nil?
    end

    # Returns the cached rows of *table*, calling the block (with `nil` for
    # "every table", or the stale table's name) when the cache cannot answer.
    def fetch(table : String, & : String? -> Array(T)) : Array(T)
      entries = @entries
      if entries.nil?
        entries = group(yield nil)
        @entries = entries
        @stale.clear
      elsif @stale.includes?(table)
        rows = yield table
        if rows.empty?
          entries.delete(table)
        else
          entries[table] = rows
        end
        @stale.delete(table)
      end
      entries[table]? || Array(T).new
    end

    # Loads every table with the block unless that already happened.
    def ensure_loaded(& : -> Array(T)) : Nil
      return if @entries
      @entries = group(yield)
      @stale.clear
    end

    def replace(rows : Array(T)) : Nil
      @entries = group(rows)
      @stale.clear
    end

    def rows : Array(T)
      result = Array(T).new
      @entries.try(&.each_value { |list| result.concat(list) })
      result
    end

    def reset(table : String? = nil) : Nil
      if table.nil?
        @entries = nil
        @stale.clear
      elsif entries = @entries
        entries.delete(table)
        @stale << table
      end
    end

    private def group(rows : Array(T)) : Hash(String, Array(T))
      grouped = Hash(String, Array(T)).new
      rows.each { |row| (grouped[row.table_name] ||= Array(T).new) << row }
      grouped
    end
  end

  # Runtime view of one connection's catalog: tables, columns, indexes, primary
  # keys and foreign keys.
  #
  # Each kind of catalog data is fetched with a single batched query and then
  # kept in memory until `#reset!`. Nothing is read per request: call
  # `#load` at boot with a file written by `#dump` to skip the catalog queries
  # altogether. `Grant::Migrator` resets the affected table after it creates or
  # drops one; run `#reset!` yourself after other DDL.
  #
  # One instance covers one namespace: a PostgreSQL schema or a MySQL database.
  # `Adapter::Base#schema` keeps one per namespace, so each schema-tenant block
  # reads its own tenant's catalog and `schema_tenant_excluded` models (whose
  # `table_name` is `public.x`) read `public`. With no namespace, PostgreSQL
  # inspects `current_schema()` and MySQL the selected database.
  #
  # ```
  # schema = Grant.schema(User.adapter)
  # schema.table_exists?(:users)       # => true
  # schema.columns(:users).map(&.name) # => ["id", "email"]
  # schema.primary_key(:users)         # => ["id"]
  # ```
  class Introspection
    FORMAT_VERSION = 1

    getter adapter : Grant::Adapter::Base
    # The PostgreSQL schema or MySQL database inspected, or `nil` for the
    # connection's current one.
    getter namespace : String?

    @mutex = Mutex.new
    @tables : Array(String)? = nil
    @columns = Bucket(ColumnInfo).new
    @indexes = Bucket(IndexInfo).new
    @foreign_keys = Bucket(ForeignKeyInfo).new

    def initialize(@adapter : Grant::Adapter::Base, @namespace : String? = nil)
    end

    def tables : Array(String)
      @mutex.synchronize { known_tables }
    end

    def table_exists?(table : String | Symbol) : Bool
      name = table.to_s
      @mutex.synchronize { known_tables.includes?(name) }
    end

    # Columns of *table* in table order. The array is shared with the cache;
    # treat it as read-only. Raises `TableNotFound` for an unknown table.
    def columns(table : String | Symbol) : Array(ColumnInfo)
      name = table.to_s
      @mutex.synchronize do
        require_table!(name)
        @columns.fetch(name) { |only| @adapter.catalog_columns(only, @namespace) }
      end
    end

    # True when *table* has *column*, optionally of the given type family.
    def column_exists?(table : String | Symbol, column : String | Symbol, type : TypeFamily? = nil) : Bool
      return false unless table_exists?(table)
      wanted = column.to_s
      columns(table).any? do |info|
        info.name == wanted && (type.nil? || info.type_family == type)
      end
    end

    # Primary key column names in key order; empty when the table has none.
    def primary_key(table : String | Symbol) : Array(String)
      columns(table).select(&.primary_key?).sort_by!(&.primary_key_position).map(&.name)
    end

    # Indexes of *table*, excluding the primary key.
    def indexes(table : String | Symbol) : Array(IndexInfo)
      name = table.to_s
      @mutex.synchronize do
        require_table!(name)
        @indexes.fetch(name) { |only| @adapter.catalog_indexes(only, @namespace) }
      end
    end

    # True when an index exists on exactly *columns* (or has *name*), and is
    # unique when *unique* is given.
    def index_exists?(table : String | Symbol, columns : Array(String | Symbol)? = nil,
                      name : String | Symbol? = nil, unique : Bool? = nil) : Bool
      return false unless table_exists?(table)
      wanted = columns.try(&.map(&.to_s))
      indexes(table).any? do |index|
        (wanted.nil? || index.columns == wanted) &&
          (name.nil? || index.name == name.to_s) &&
          (unique.nil? || index.unique == unique)
      end
    end

    # Foreign keys declared on *table*.
    def foreign_keys(table : String | Symbol) : Array(ForeignKeyInfo)
      name = table.to_s
      @mutex.synchronize do
        require_table!(name)
        @foreign_keys.fetch(name) { |only| @adapter.catalog_foreign_keys(only, @namespace) }
      end
    end

    # True when *table* has a foreign key to *to_table* (and on *column*, when
    # given).
    def foreign_key_exists?(table : String | Symbol, to_table : String | Symbol? = nil,
                            column : String | Symbol? = nil) : Bool
      return false unless table_exists?(table)
      foreign_keys(table).any? do |key|
        (to_table.nil? || key.to_table == to_table.to_s) &&
          (column.nil? || key.columns == [column.to_s])
      end
    end

    # Forgets cached catalog data. With *table*, only that table is re-read on
    # its next use. Call it after DDL Grant did not run itself.
    def reset!(table : String | Symbol? = nil) : Nil
      name = table.try(&.to_s)
      @mutex.synchronize do
        @tables = nil
        @columns.reset(name)
        @indexes.reset(name)
        @foreign_keys.reset(name)
      end
    end

    # True when every kind of catalog data is in memory.
    def loaded? : Bool
      @mutex.synchronize { !@tables.nil? && @columns.loaded? && @indexes.loaded? && @foreign_keys.loaded? }
    end

    # Loads every kind of catalog data now, with one query per kind.
    def load_all! : Nil
      @mutex.synchronize { warm }
    end

    # Writes the whole catalog to *path* as JSON, for `#load` at boot.
    def dump(path : String) : Nil
      file = @mutex.synchronize do
        warm
        CacheFile.new(FORMAT_VERSION, @adapter.adapter_name, known_tables,
          @columns.rows, @indexes.rows, @foreign_keys.rows)
      end
      File.write(path, file.to_pretty_json)
    end

    # Replaces the cache with a file written by `#dump`, running no catalog
    # queries. Raises `CacheFileError` when the file is unreadable, comes from
    # another adapter, or has an unknown format version.
    def load(path : String) : Nil
      file = begin
        CacheFile.from_json(File.read(path))
      rescue ex : File::Error | JSON::ParseException | JSON::SerializableError
        raise CacheFileError.new("Cannot read schema cache #{path}: #{ex.message}", ex)
      end
      unless file.version == FORMAT_VERSION
        raise CacheFileError.new("Schema cache #{path} has format version #{file.version}, expected #{FORMAT_VERSION}")
      end
      unless file.adapter == @adapter.adapter_name
        raise CacheFileError.new("Schema cache #{path} was dumped from #{file.adapter}, not #{@adapter.adapter_name}")
      end
      @mutex.synchronize do
        @tables = file.tables
        @columns.replace(file.columns)
        @indexes.replace(file.indexes)
        @foreign_keys.replace(file.foreign_keys)
      end
    end

    # Like `#load`, but returns false instead of raising when *path* does not
    # exist, so boot code can fall back to lazy loading.
    def load?(path : String) : Bool
      return false unless File.exists?(path)
      load(path)
      true
    end

    # Compares the columns *model* declares with the table. See `Drift`.
    def verify(model : T.class, strict : Bool = false) : Array(Drift) forall T
      table = model.table_name.rpartition('.').last
      Verifier.new(self, table, model.declared_schema_columns, strict).drift
    end

    # Like `#verify`, raising `DriftError` when anything drifted.
    def verify!(model : T.class, strict : Bool = false) : Nil forall T
      found = verify(model, strict)
      raise DriftError.new(model.name, found) unless found.empty?
    end

    private def known_tables : Array(String)
      @tables ||= @adapter.catalog_tables(@namespace)
    end

    private def require_table!(name : String) : Nil
      raise TableNotFound.new(name) unless known_tables.includes?(name)
    end

    private def warm : Nil
      known_tables
      @columns.ensure_loaded { @adapter.catalog_columns(nil, @namespace) }
      @indexes.ensure_loaded { @adapter.catalog_indexes(nil, @namespace) }
      @foreign_keys.ensure_loaded { @adapter.catalog_foreign_keys(nil, @namespace) }
    end
  end
end

abstract class Grant::Adapter::Base
  @schema_caches = Hash(String, Grant::Schema::Introspection).new
  @schema_caches_mutex = Mutex.new

  # The schema cache of this connection for *namespace* (a PostgreSQL schema or
  # MySQL database). Without *namespace* it is the active schema-tenant schema
  # when this fiber is inside `Grant::SchemaTenant.with` on this adapter, and
  # the connection's current schema otherwise, so tenants never share a cache.
  def schema(namespace : String? = nil) : Grant::Schema::Introspection
    key = namespace || Grant::SchemaTenant.current_schema_for?(self) || ""
    @schema_caches_mutex.synchronize do
      @schema_caches[key] ||= Grant::Schema::Introspection.new(self, key.presence)
    end
  end

  # Forgets *table* in every namespace's schema cache of this connection, or
  # everything when *table* is nil. `Grant::Migrator` calls it after DDL.
  def reset_schema_caches!(table : String? = nil) : Nil
    caches = @schema_caches_mutex.synchronize { @schema_caches.values }
    caches.each(&.reset!(table))
  end

  # Drops the schema cache kept for *namespace*, e.g. after its schema is
  # dropped, so per-tenant caches do not outlive their tenant.
  def forget_schema_cache(namespace : String) : Nil
    @schema_caches_mutex.synchronize { @schema_caches.delete(namespace) }
  end

  # Names of the tables in *namespace* (default: the connection's current
  # schema), ordered by name.
  def catalog_tables(namespace : String? = nil) : Array(String)
    raise Grant::Schema::IntrospectionNotSupported.new(adapter_name)
  end

  # Columns of *table*, or of every table when it is nil, in one query. Rows are
  # ordered by table then position.
  def catalog_columns(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ColumnInfo)
    raise Grant::Schema::IntrospectionNotSupported.new(adapter_name)
  end

  # Non-primary-key indexes of *table*, or of every table when it is nil, in one
  # query.
  def catalog_indexes(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::IndexInfo)
    raise Grant::Schema::IntrospectionNotSupported.new(adapter_name)
  end

  # Foreign keys of *table*, or of every table when it is nil, in one query.
  def catalog_foreign_keys(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ForeignKeyInfo)
    raise Grant::Schema::IntrospectionNotSupported.new(adapter_name)
  end

  # Runs one catalog *sql* statement and yields each row of the result set.
  protected def catalog_query(sql : String, args : Array(DB::Any) = [] of DB::Any, & : DB::ResultSet ->) : Nil
    elapsed_time = Time.measure do
      open(sql, args) do |db|
        db.query sql, args: args do |rs|
          rs.each { yield rs }
        end
      end
    end
    log sql, elapsed_time, args
  end
end

module Grant
  # The schema cache of the default connection, or of *database*'s writer.
  def self.schema(database : String = Grant::Base.default_database_name) : Grant::Schema::Introspection
    Grant::ConnectionRegistry.get_adapter(database).schema
  end

  # The schema cache of *adapter*'s connection.
  def self.schema(adapter : Grant::Adapter::Base) : Grant::Schema::Introspection
    adapter.schema
  end
end

require "./verify"
