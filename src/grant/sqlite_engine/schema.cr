module Grant::SQLiteEngine
  # One row of `sqlite_schema` (fileformat2.html §2.6).
  struct SchemaEntry
    # "table", "index", "view" or "trigger".
    getter object_type : String
    getter object_name : String
    getter table_name : String
    # Root b-tree page; 0 for views, triggers and virtual tables.
    getter root_page : UInt32
    # The CREATE statement; nil for automatic indexes.
    getter sql : String?

    def initialize(@object_type : String, @object_name : String, @table_name : String, @root_page : UInt32, @sql : String?)
    end

    def table? : Bool
      @object_type == "table"
    end

    def index? : Bool
      @object_type == "index"
    end

    # True for a table backed by a b-tree (not a virtual table).
    def has_a_btree? : Bool
      @root_page != 0
    end
  end

  # The database schema: every entry of `sqlite_schema`, with each table's
  # parsed definition.
  class Schema
    getter list_of_entries : Array(SchemaEntry)

    @table_definitions = {} of String => TableDefinition

    def initialize(@list_of_entries : Array(SchemaEntry))
    end

    # The table or index entry named *object_name* (case-insensitive, as
    # SQLite matches names).
    def entry(object_name : String) : SchemaEntry
      found = @list_of_entries.find { |entry| entry.object_name.compare(object_name, case_insensitive: true) == 0 }
      raise UnknownSchemaObject.new(object_name) unless found
      found
    end

    # Tables backed by a b-tree, in schema order.
    def list_of_tables : Array(SchemaEntry)
      @list_of_entries.select { |entry| entry.table? && entry.has_a_btree? }
    end

    # Indexes, in schema order.
    def list_of_indexes : Array(SchemaEntry)
      @list_of_entries.select { |entry| entry.index? && entry.has_a_btree? }
    end

    # The parsed CREATE TABLE of *table_name*. A statement the reader cannot
    # read means the schema itself is damaged.
    def table_definition(table_name : String) : TableDefinition
      table_definition(entry(table_name))
    end

    # The parsed CREATE TABLE of the table *entry* names.
    def table_definition(entry : SchemaEntry) : TableDefinition
      key = entry.object_name.downcase
      if cached = @table_definitions[key]?
        return cached
      end
      sql = entry.sql
      raise CorruptDatabase.new("table #{entry.object_name} has no CREATE statement", 1_u32) unless sql
      definition = begin
        TableDefinition.parse(sql)
      rescue error : SchemaTokenizer::Malformed
        raise CorruptDatabase.new("malformed database schema (#{entry.object_name}): #{error.message}", 1_u32)
      end
      @table_definitions[key] = definition
    end

    # Affinity of each value in an index record: the key columns, then the
    # rowid (rowid tables) or the primary key columns (WITHOUT ROWID tables).
    # A primary key column is left out only when the key already holds it
    # with the same collation (sqlite3CreateIndex). Expressions have no
    # affinity.
    def index_record_affinities(index_entry : SchemaEntry) : Array(Affinity)
      table_entry = @list_of_entries.find { |entry| entry.table? && entry.object_name.compare(index_entry.table_name, case_insensitive: true) == 0 }
      raise CorruptDatabase.new("index #{index_entry.object_name} names missing table #{index_entry.table_name}", 1_u32) unless table_entry
      table = table_definition(table_entry)
      key_terms = index_key_terms(index_entry, table)
      affinities = key_terms.map { |term| column_affinity(table, term.column_name) }
      unless table.without_rowid?
        affinities << Affinity::Integer
        return affinities
      end
      key_collations = key_terms.map { |term| {term.column_name.try(&.downcase), effective_collation(table, term)} }
      table.list_of_primary_key_columns.each_with_index do |column_name, position|
        held = {column_name.downcase, table.primary_key_collation(position).downcase}
        affinities << column_affinity(table, column_name) unless key_collations.includes?(held)
      end
      affinities
    end

    private def effective_collation(table : TableDefinition, term : IndexDefinition::KeyTerm) : String
      explicit = term.collation
      return explicit.downcase if explicit
      column_name = term.column_name
      index = column_name ? table.column_index(column_name) : nil
      (index ? table.list_of_columns[index].collation : "BINARY").downcase
    end

    private def index_key_terms(index_entry : SchemaEntry, table : TableDefinition) : Array(IndexDefinition::KeyTerm)
      sql = index_entry.sql
      if sql
        begin
          return IndexDefinition.parse(sql).list_of_key_terms
        rescue error : SchemaTokenizer::Malformed
          raise CorruptDatabase.new("malformed database schema (#{index_entry.object_name}): #{error.message}", 1_u32)
        end
      end
      # Automatic indexes are named sqlite_autoindex_<table>_<n>, numbered in
      # the order their constraints appear.
      number = index_entry.object_name.rpartition('_').last.to_i?
      constraint = number && number > 0 ? table.list_of_unique_constraints[number - 1]? : nil
      return [] of IndexDefinition::KeyTerm unless constraint
      constraint.map { |column_name| IndexDefinition::KeyTerm.new(column_name, nil) }
    end

    private def column_affinity(table : TableDefinition, column_name : String?) : Affinity
      return Affinity::Blob unless column_name
      index = table.column_index(column_name)
      index ? table.list_of_columns[index].affinity : Affinity::Blob
    end
  end
end
