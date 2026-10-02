require "digest/crc32"
require "./table_definition"

module Grant::Schema
  # Names derived from table and column names, shared by the DDL statements.
  module Naming
    IRREGULAR_SINGULARS = {"people" => "person", "men" => "man", "women" => "woman", "children" => "child", "mice" => "mouse", "feet" => "foot", "teeth" => "tooth"}

    # The singular of the last word of a snake_case table *name* (`users` =>
    # `user`, `categories` => `category`). Regular English plurals only.
    def self.singularize(name : ::String) : ::String
      words = name.split('_')
      word = words.pop
      singular = if irregular = IRREGULAR_SINGULARS[word]?
                   irregular
                 elsif word.size > 3 && word.ends_with?("ies")
                   word[0...-3] + "y"
                 elsif word.ends_with?("ses") || word.ends_with?("xes") || word.ends_with?("zes") || word.ends_with?("ches") || word.ends_with?("shes")
                   word[0...-2]
                 elsif word.ends_with?('s') && !word.ends_with?("ss")
                   word[0...-1]
                 else
                   word
                 end
      words << singular
      words.join('_')
    end

    # The foreign key column that refers to *table*: `users` => `user_id`.
    def self.foreign_key_column(table : ::String | Symbol) : ::String
      "#{singularize(table.to_s.rpartition('.').last)}_id"
    end

    # The schema (or MySQL database) part of a dotted table name, or nil.
    def self.schema_of(table : ::String | Symbol) : ::String?
      schema, dot, _ = table.to_s.rpartition('.')
      dot.empty? ? nil : schema
    end

    # *name* prefixed with the schema of *table* when it has one. PostgreSQL
    # and SQLite keep an index in its table's schema, and DROP, ALTER and
    # COMMENT have to say which.
    def self.in_schema_of(table : ::String | Symbol, name : ::String | Symbol) : ::String
      schema = schema_of(table)
      schema ? "#{schema}.#{name}" : name.to_s
    end

    # `index_<table>_on_<a>_and_<b>`, ActiveRecord's default index name.
    def self.index_name(table : ::String | Symbol, columns : Array(::String)) : ::String
      "index_#{table.to_s.rpartition('.').last}_on_#{columns.join("_and_")}"
    end

    # A short stable digest of *text*, for names that must not grow with it.
    def self.digest(text : ::String) : ::String
      Digest::CRC32.checksum(text).to_s(16).rjust(8, '0')
    end

    # A constraint name `<prefix>_<table>_<detail>`, shortened with a digest
    # when it would exceed the 63 characters every dialect accepts.
    def self.constraint_name(prefix : ::String, table : ::String | Symbol, detail : ::String) : ::String
      name = "#{prefix}_#{table.to_s.rpartition('.').last}_#{detail}"
      return name if name.size <= 60
      "#{name[0, 50]}_#{digest(name)}"
    end

    # The name of the join table between *first* and *second*: the two table
    # names in alphabetical order joined by `_`.
    def self.join_table_name(first : ::String | Symbol, second : ::String | Symbol) : ::String
      [first.to_s, second.to_s].sort.join('_')
    end

    # True when *text* is a plain column name rather than an expression.
    def self.identifier?(text : ::String) : Bool
      text.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end
  end

  # One index: what `add_index`, `t.index` and `IndexInfo` round trips build.
  #
  # Columns that are not plain names are expressions (`"lower(email)"`). They
  # are emitted in parentheses and need an explicit *name*.
  class IndexDefinition
    getter table : ::String
    getter columns : Array(::String)
    getter? unique : Bool
    getter where : ::String?
    getter using : ::String?
    getter order : Hash(::String, ::String)
    getter opclass : Hash(::String, ::String)
    getter covering : Array(::String)
    getter length : Hash(::String, Int32)
    getter algorithm : Symbol?
    getter? if_not_exists : Bool
    getter comment : ::String?

    def initialize(@table : ::String, @columns : Array(::String), name : ::String? = nil, @unique : Bool = false,
                   @where : ::String? = nil, @using : ::String? = nil,
                   @order : Hash(::String, ::String) = {} of ::String => ::String,
                   @opclass : Hash(::String, ::String) = {} of ::String => ::String,
                   @covering : Array(::String) = [] of ::String,
                   @length : Hash(::String, Int32) = {} of ::String => Int32,
                   @algorithm : Symbol? = nil, @if_not_exists : Bool = false, @comment : ::String? = nil)
      raise InvalidDefinition.new("Index on '#{@table}' needs at least one column") if @columns.empty?
      @name = name
      if name.nil? && @columns.any? { |column| !Naming.identifier?(column) }
        raise InvalidDefinition.new("An expression index on '#{@table}' needs an explicit name:")
      end
    end

    def name : ::String
      @name || Naming.index_name(@table, @columns)
    end

    # Builds the definition from the common `add_index` arguments.
    def self.build(table : TableName, columns : ColumnNames, name : ::String | Symbol? = nil, unique : Bool = false,
                   where : ::String? = nil, using : ::String | Symbol? = nil,
                   order = nil,
                   opclass = nil,
                   include covering : ColumnNames? = nil, length = nil,
                   algorithm : Symbol? = nil, if_not_exists : Bool = false, comment : ::String? = nil) : IndexDefinition
      names = to_names(columns)
      orders = {} of ::String => ::String
      case order
      when Symbol           then names.each { |column| orders[column] = order.to_s.upcase }
      when Hash, NamedTuple then order.each { |column, direction| orders[column.to_s] = direction.to_s.upcase }
      end
      classes = {} of ::String => ::String
      case opclass
      when ::String         then names.each { |column| classes[column] = opclass }
      when Hash, NamedTuple then opclass.each { |column, klass| classes[column.to_s] = klass }
      end
      lengths = {} of ::String => Int32
      case length
      when Int32            then names.each { |column| lengths[column] = length }
      when Hash, NamedTuple then length.each { |column, size| lengths[column.to_s] = size }
      end
      new(table.to_s, names, name.try(&.to_s), unique, where, using.try(&.to_s), orders, classes,
        covering ? to_names(covering) : [] of ::String, lengths, algorithm, if_not_exists, comment)
    end

    # The definition that recreates *info* (for a rename on SQLite, which has
    # no `ALTER INDEX`).
    def self.from_info(info : IndexInfo, columns : Array(::String) = info.columns, name : ::String = info.name) : IndexDefinition
      new(info.table_name, columns, name, info.unique?, info.where)
    end

    def self.to_names(columns : ColumnNames) : Array(::String)
      case columns
      in ::String, Symbol then [columns.to_s]
      in Array            then columns.map(&.to_s)
      end
    end

    # `CREATE INDEX` for *dialect*.
    #
    # Options a dialect cannot express raise `UnsupportedOperation`:
    # `where:` and `include:` on MySQL, `include:` and `opclass:` on SQLite,
    # `using:` other than btree on SQLite, `length:` off MySQL. `algorithm:
    # :concurrently` builds without blocking writes on PostgreSQL and is
    # ignored elsewhere; `:inplace`, `:copy` and `:default` set MySQL's
    # `ALGORITHM=`.
    def to_sql(dialect : Dialect) : ::String
      validate_for(dialect)
      String.build do |io|
        io << "CREATE "
        io << "UNIQUE " if unique?
        if dialect.mysql? && (kind = @using) && {"fulltext", "spatial"}.includes?(kind.downcase)
          io << kind.upcase << ' '
        end
        io << "INDEX "
        io << "CONCURRENTLY " if dialect.pg? && @algorithm == :concurrently
        io << "IF NOT EXISTS " if @if_not_exists && !dialect.mysql?
        # SQLite names the schema on the index and not on the table.
        if dialect.sqlite?
          io << dialect.quote(Naming.in_schema_of(@table, name)) << " ON " << dialect.quote(@table.rpartition('.').last)
        else
          io << dialect.quote(name) << " ON " << dialect.quote(@table)
        end
        io << " USING " << @using if dialect.pg? && @using
        io << " (" << @columns.map { |column| column_sql(dialect, column) }.join(", ") << ')'
        if dialect.mysql? && (using = @using) && !{"fulltext", "spatial"}.includes?(using.downcase)
          io << " USING " << using.upcase
        end
        io << " INCLUDE (" << @covering.map { |column| dialect.quote(column) }.join(", ") << ')' unless @covering.empty?
        io << " WHERE " << @where if @where
        if dialect.mysql? && (algorithm = @algorithm) && {:inplace, :copy, :default}.includes?(algorithm)
          io << " ALGORITHM=" << algorithm.to_s.upcase
        end
        if dialect.mysql? && (text = @comment)
          io << " COMMENT " << dialect.quote_literal(text)
        end
      end
    end

    # All statements that create the index: the `CREATE INDEX`, and on
    # PostgreSQL a `COMMENT ON INDEX`.
    def statements(dialect : Dialect) : Array(::String)
      result = [to_sql(dialect)]
      if dialect.pg? && (text = @comment)
        result << "COMMENT ON INDEX #{dialect.quote(Naming.in_schema_of(@table, name))} IS #{dialect.quote_literal(text)}"
      end
      result
    end

    # True when the statement cannot run inside a transaction.
    def concurrent?(dialect : Dialect) : Bool
      dialect.pg? && @algorithm == :concurrently
    end

    private def column_sql(dialect : Dialect, column : ::String) : ::String
      sql = Naming.identifier?(column) ? dialect.quote(column) : "(#{column})"
      if size = @length[column]?
        sql += "(#{size})"
      end
      if klass = @opclass[column]?
        sql += " #{klass}"
      end
      if direction = @order[column]?
        raise InvalidDefinition.new("Unknown index order #{direction.inspect} for '#{column}'") unless {"ASC", "DESC"}.includes?(direction)
        sql += " #{direction}"
      end
      sql
    end

    private def validate_for(dialect : Dialect) : Nil
      unless @algorithm.nil?
        unless {:concurrently, :inplace, :copy, :default}.includes?(@algorithm)
          raise InvalidDefinition.new("Unknown index algorithm #{@algorithm.inspect}")
        end
      end
      if dialect.mysql?
        raise UnsupportedOperation.new("MySQL has no partial indexes (where: on '#{name}')") if @where
        raise UnsupportedOperation.new("MySQL has no INCLUDE columns (index '#{name}')") unless @covering.empty?
        raise UnsupportedOperation.new("MySQL has no IF NOT EXISTS for indexes ('#{name}')") if @if_not_exists
        raise UnsupportedOperation.new("MySQL has no operator classes (index '#{name}')") unless @opclass.empty?
      else
        raise UnsupportedOperation.new("Index prefix length: is only supported on MySQL ('#{name}')") unless @length.empty?
      end
      if dialect.sqlite?
        raise UnsupportedOperation.new("SQLite has no INCLUDE columns (index '#{name}')") unless @covering.empty?
        raise UnsupportedOperation.new("SQLite has no operator classes (index '#{name}')") unless @opclass.empty?
        if (kind = @using) && kind.downcase != "btree"
          raise UnsupportedOperation.new("SQLite only has btree indexes (using: #{kind.inspect} on '#{name}')")
        end
      end
      max = dialect.pg? ? 63 : 64
      raise InvalidDefinition.new("Index name '#{name}' is longer than #{max} characters") if name.size > max
    end
  end
end
