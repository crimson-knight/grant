require "json"
require "./table_rebuild"
require "./introspection"

module Grant::Schema
  # One `CHECK` constraint of a table.
  struct CheckConstraintInfo
    include JSON::Serializable

    getter table_name : ::String
    getter name : ::String?
    getter expression : ::String
    # False for a PostgreSQL constraint added `NOT VALID` and not yet validated.
    getter validated : Bool

    def initialize(@table_name : ::String, @name : ::String?, @expression : ::String, @validated : Bool = true)
    end

    def validated? : Bool
      @validated
    end
  end

  # One `UNIQUE` constraint (not a bare unique index) of a table.
  struct UniqueConstraintInfo
    include JSON::Serializable

    getter table_name : ::String
    getter name : ::String?
    getter columns : Array(::String)
    getter deferrable : Bool

    def initialize(@table_name : ::String, @name : ::String?, @columns : Array(::String), @deferrable : Bool = false)
    end

    def deferrable? : Bool
      @deferrable
    end
  end

  # One PostgreSQL exclusion constraint.
  struct ExclusionConstraintInfo
    include JSON::Serializable

    getter table_name : ::String
    getter name : ::String
    getter definition : ::String

    def initialize(@table_name : ::String, @name : ::String, @definition : ::String)
    end
  end

  class Introspection
    # `CHECK` constraints of *table*, read from the database on each call.
    def check_constraints(table : ::String | Symbol) : Array(CheckConstraintInfo)
      name = table.to_s
      result = [] of CheckConstraintInfo
      case Dialect.for(@adapter)
      in .pg?
        catalog_rows(<<-SQL, name) do |rs|
          SELECT c.conname::text, pg_get_expr(c.conbin, c.conrelid), c.convalidated
          FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.contype = 'c' AND n.nspname = current_schema() AND t.relname = $1 ORDER BY c.conname
          SQL
          result << CheckConstraintInfo.new(name, rs.read(::String), rs.read(::String), rs.read(Bool))
        end
      in .mysql?
        catalog_rows(<<-SQL, name) do |rs|
          SELECT CAST(cc.CONSTRAINT_NAME AS CHAR), CAST(cc.CHECK_CLAUSE AS CHAR)
          FROM information_schema.CHECK_CONSTRAINTS cc
          JOIN information_schema.TABLE_CONSTRAINTS tc ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
          WHERE tc.TABLE_SCHEMA = DATABASE() AND tc.TABLE_NAME = ? AND tc.CONSTRAINT_TYPE = 'CHECK' ORDER BY cc.CONSTRAINT_NAME
          SQL
          result << CheckConstraintInfo.new(name, rs.read(::String), rs.read(::String))
        end
      in .sqlite?
        sqlite_items(name).each do |item|
          next unless item.kind == :check
          result << CheckConstraintInfo.new(name, item.name, TableRebuild::Scanner.check_expression(item.text).strip)
        end
      end
      result
    end

    # `UNIQUE` constraints of *table*. PostgreSQL also lists the backing
    # index in `#indexes`.
    def unique_constraints(table : ::String | Symbol) : Array(UniqueConstraintInfo)
      name = table.to_s
      result = [] of UniqueConstraintInfo
      case Dialect.for(@adapter)
      in .pg?
        catalog_rows(<<-SQL, name) do |rs|
          SELECT c.conname::text, c.condeferrable,
                 (SELECT array_agg(a.attname::text ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
                  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
          FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.contype = 'u' AND n.nspname = current_schema() AND t.relname = $1 ORDER BY c.conname
          SQL
          key = rs.read(::String)
          deferrable = rs.read(Bool)
          result << UniqueConstraintInfo.new(name, key, rs.read(Array(::String)), deferrable)
        end
      in .mysql?
        catalog_rows(<<-SQL, name) do |rs|
          SELECT CAST(tc.CONSTRAINT_NAME AS CHAR), CAST(k.COLUMN_NAME AS CHAR)
          FROM information_schema.TABLE_CONSTRAINTS tc
          JOIN information_schema.KEY_COLUMN_USAGE k ON k.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME = tc.CONSTRAINT_NAME AND k.TABLE_NAME = tc.TABLE_NAME
          WHERE tc.TABLE_SCHEMA = DATABASE() AND tc.TABLE_NAME = ? AND tc.CONSTRAINT_TYPE = 'UNIQUE'
          ORDER BY tc.CONSTRAINT_NAME, k.ORDINAL_POSITION
          SQL
          key = rs.read(::String)
          column = rs.read(::String)
          if (last = result.last?) && last.name == key
            result[-1] = UniqueConstraintInfo.new(name, key, last.columns + [column])
          else
            result << UniqueConstraintInfo.new(name, key, [column])
          end
        end
      in .sqlite?
        sqlite_items(name).each do |item|
          next unless item.kind == :unique
          result << UniqueConstraintInfo.new(name, item.name, TableRebuild::Scanner.fk_columns(item.text))
        end
      end
      result
    end

    # Exclusion constraints of *table* (PostgreSQL; none elsewhere).
    def exclusion_constraints(table : ::String | Symbol) : Array(ExclusionConstraintInfo)
      name = table.to_s
      result = [] of ExclusionConstraintInfo
      return result unless Dialect.for(@adapter).pg?
      catalog_rows(<<-SQL, name) do |rs|
        SELECT c.conname::text, pg_get_constraintdef(c.oid)
        FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.contype = 'x' AND n.nspname = current_schema() AND t.relname = $1 ORDER BY c.conname
        SQL
        result << ExclusionConstraintInfo.new(name, rs.read(::String), rs.read(::String))
      end
      result
    end

    # The comment on *table*, or nil (always nil on SQLite).
    def table_comment(table : ::String | Symbol) : ::String?
      name = table.to_s
      comment = nil.as(::String?)
      case Dialect.for(@adapter)
      in .pg?
        catalog_rows("SELECT obj_description(to_regclass(quote_ident(current_schema()) || '.' || quote_ident($1)), 'pg_class')", name) do |rs|
          comment = rs.read(::String?)
        end
      in .mysql?
        catalog_rows("SELECT CAST(TABLE_COMMENT AS CHAR) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?", name) do |rs|
          text = rs.read(::String?)
          comment = text unless text.nil? || text.empty?
        end
      in .sqlite?
      end
      comment
    end

    # PostgreSQL enum types and their values in order; empty elsewhere.
    def enums : Hash(::String, Array(::String))
      result = {} of ::String => Array(::String)
      return result unless Dialect.for(@adapter).pg?
      catalog_rows(<<-SQL, nil) do |rs|
        SELECT t.typname::text, array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = current_schema() GROUP BY t.typname ORDER BY t.typname
        SQL
        result[rs.read(::String)] = rs.read(Array(::String))
      end
      result
    end

    # Installed PostgreSQL extensions; empty elsewhere.
    def extensions : Array(::String)
      result = [] of ::String
      return result unless Dialect.for(@adapter).pg?
      catalog_rows("SELECT extname::text FROM pg_extension ORDER BY extname", nil) { |rs| result << rs.read(::String) }
      result
    end

    def extension_enabled?(name : ::String | Symbol) : Bool
      extensions.includes?(name.to_s)
    end

    private def sqlite_items(table : ::String) : Array(TableRebuild::Item)
      sql = nil.as(::String?)
      catalog_rows("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", table) { |rs| sql = rs.read(::String?) }
      text = sql
      return [] of TableRebuild::Item unless text
      TableRebuild.new(table, text).items
    end

    private def catalog_rows(sql : ::String, argument : ::String?, & : DB::ResultSet ->) : Nil
      args = argument ? [argument.as(DB::Any)] : [] of DB::Any
      @adapter.open(sql, args) do |db|
        db.query sql, args: args do |rs|
          rs.each { yield rs }
        end
      end
    end
  end
end
