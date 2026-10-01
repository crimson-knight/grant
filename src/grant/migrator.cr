require "./error"
require "./adapter/schema"

# DB migration tool that prepares a table for the class
#
# ```
# class User < Grant::Base
#   adapter mysql
#   field name : String
# end
#
# User.migrator.drop_and_create
# # => "DROP TABLE IF EXISTS `users`;"
# # => "CREATE TABLE `users` (id BIGSERIAL PRIMARY KEY, name VARCHAR(255));"
#
# User.migrator(table_options: "ENGINE=InnoDB DEFAULT CHARSET=utf8").create
# # => "CREATE TABLE ... ENGINE=InnoDB DEFAULT CHARSET=utf8;"
# ```
#
# Column options on `column` shape the DDL: `null:`, `limit:` (String),
# `precision:` and `scale:` (BigDecimal, Time), `comment:`, `collation:`,
# `default_sql:` (a SQL expression such as `"CURRENT_TIMESTAMP"`), and
# `column_type:` for a verbatim SQL type. Several `primary: true` columns give a
# composite `PRIMARY KEY (a, b)`.
#
# ```
# class Invoice < Grant::Base
#   column id : Int64, primary: true
#   column code : String, limit: 20, collation: "C", comment: "Public code"
#   column issued_at : Time, precision: 3, default_sql: "CURRENT_TIMESTAMP"
# end
#
# Invoice.migrator.create(if_not_exists: true, comment: "Invoices")
# ```
#
# For tables that do not come from a model, see `Grant::Schema::SchemaStatements`.
#
# These are DDL statements. A constant default on an existing table is
# metadata-only on PostgreSQL 11+ and may rewrite the table on MySQL.
module Grant::Migrator
  module ClassMethods
    def migrator(**args)
      Migrator(self).new(**args)
    end
  end

  class Migrator(Model)
    def initialize(@table_options = "")
    end

    private def default_clause_for(value) : String
      case value
      when String
        " DEFAULT '#{value.gsub("'", "''")}'"
      when Bool
        " DEFAULT #{value ? "TRUE" : "FALSE"}"
      when Number
        " DEFAULT #{value}"
      when Nil
        " DEFAULT NULL"
      else
        ""
      end
    end

    def drop_and_create
      drop
      create
    end

    def drop_sql(if_exists : Bool = true, cascade : Bool = false)
      "DROP TABLE #{"IF EXISTS " if if_exists}#{Model.quoted_table_name}#{" CASCADE" if cascade && dialect.pg?};"
    end

    def drop(if_exists : Bool = true, cascade : Bool = false)
      Model.unscoped { |_scope| Model.exec drop_sql(if_exists, cascade) }
      Model.adapter.reset_schema_caches!(Model.table_name.rpartition('.').last)
    end

    # SQL of the `CREATE TABLE` statement. *comment* is a table comment; it is
    # part of this statement on MySQL, a separate `COMMENT ON` statement
    # (see `#create_statements`) on PostgreSQL, and skipped on SQLite.
    def create_sql(if_not_exists : Bool = false, temporary : Bool = false, comment : String? = nil)
      String.build do |s|
        s << "CREATE "
        s << "TEMPORARY " if temporary
        s << "TABLE "
        s << "IF NOT EXISTS " if if_not_exists
        s.puts "#{Model.quoted_table_name}("

        # primary key
        {% begin %}
          {% primary_keys = Model.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
          {% raise "A primary key must be defined for #{Model.name}." if primary_keys.empty? %}
          {% if primary_keys.size == 1 %}
            {% primary_key = primary_keys.first %}
            {% ann = primary_key.annotation(Grant::Column) %}
            k = Model.adapter.quote("{{primary_key.name}}")
            v =
              {% if ann[:auto] %}
                native_type("AUTO_{{primary_key.type.union_types.find { |t| t != Nil }.id}}")
              {% else %}
                native_type("{{primary_key.type.union_types.find { |t| t != Nil }.id}}")
              {% end %}
            default_clause = {% if !ann[:auto] && primary_key.has_default_value? %}
              {% default_value = primary_key.default_value %}
              {% if default_value.is_a?(StringLiteral) || default_value.is_a?(NumberLiteral) || default_value.is_a?(BoolLiteral) || default_value.is_a?(NilLiteral) %}
                default_clause_for({{default_value}})
              {% else %}
                ""
              {% end %}
            {% else %}
              ""
            {% end %}
            s.print "#{k} #{v} PRIMARY KEY#{default_clause}"
          {% else %}
            {% for ivar, index in primary_keys %}
              {% ann = ivar.annotation(Grant::Column) %}
              {% key = ivar.type.union_types.find { |t| t != Nil }.id.stringify %}
              {% key = "Bytes" if key == "Slice(UInt8)" %}
              {% if index > 0 %}
                s.puts ","
              {% end %}
              s.print column_line("{{ivar.name}}", "{{key.id}}", {{ann[:column_type]}}, false, false, false, false,
                {{ann[:limit]}}, {{ann[:precision]}}, {{ann[:scale]}}, {{ann[:comment]}}, {{ann[:collation]}}, {{ann[:default_sql]}},
                {% if ivar.has_default_value? %}
                  {% default_value = ivar.default_value %}
                  {% if default_value.is_a?(StringLiteral) || default_value.is_a?(NumberLiteral) || default_value.is_a?(BoolLiteral) || default_value.is_a?(NilLiteral) %}
                    default_clause_for({{default_value}})
                  {% else %}
                    ""
                  {% end %}
                {% else %}
                  ""
                {% end %}
              )
            {% end %}
            s.puts
          {% end %}
        {% end %}

        # content fields
        {% for ivar in Model.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && !ann[:primary] } %}
          {% ann = ivar.annotation(Grant::Column) %}
          {% key = ivar.type.union_types.find { |t| t != Nil } %}
          {% if key < Enum %}
            # An enum is stored through `Grant::Converters::Enum(E, T)`: map
            # the column to `T`, which is `String` unless the model says so.
            {% converter = ann[:converter] %}
            {% key = converter.is_a?(Generic) && converter.type_vars.size == 2 ? converter.type_vars.last.resolve.id.stringify : "String" %}
          {% else %}
            {% key = key.id.stringify %}
          {% end %}
          {% key = "Bytes" if key == "Slice(UInt8)" %}
          s.puts ","
          s.puts column_line("{{ivar.name}}", "{{key.id}}", {{ann[:column_type]}},
            {{ivar.name.id == "created_at" || ivar.name.id == "updated_at"}}, {{ann[:nilable] ? true : false}}, {{ann[:null]}}, false,
            {{ann[:limit]}}, {{ann[:precision]}}, {{ann[:scale]}}, {{ann[:comment]}}, {{ann[:collation]}}, {{ann[:default_sql]}},
            {% if ivar.has_default_value? %}
              {% default_value = ivar.default_value %}
              {% if default_value.is_a?(StringLiteral) || default_value.is_a?(NumberLiteral) || default_value.is_a?(BoolLiteral) || default_value.is_a?(NilLiteral) %}
                default_clause_for({{default_value}})
              {% else %}
                ""
              {% end %}
            {% else %}
              ""
            {% end %}
          )
        {% end %}

        {% begin %}
          {% primary_keys = Model.instance_vars.select { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
          {% if primary_keys.size > 1 %}
            s.puts ","
            s.puts "PRIMARY KEY (#{ {{primary_keys.map(&.name.stringify)}}.map { |name| Model.adapter.quote(name) }.join(", ") })"
          {% end %}
        {% end %}

        s << ")"
        s << " COMMENT=#{dialect.quote_literal(comment)}" if comment && dialect.mysql?
        s.puts " #{@table_options};"
      end
    end

    # Every statement that creates the table: `#create_sql`, then on PostgreSQL
    # the `COMMENT ON` statements for the table and its commented columns.
    def create_statements(if_not_exists : Bool = false, temporary : Bool = false, comment : String? = nil) : Array(String)
      statements = [create_sql(if_not_exists, temporary, comment)]
      if dialect.pg?
        table = Model.quoted_table_name
        if text = comment
          statements << "COMMENT ON TABLE #{table} IS #{dialect.quote_literal(text)}"
        end
        column_comments.each do |name, text|
          statements << "COMMENT ON COLUMN #{table}.#{Model.adapter.quote(name)} IS #{dialect.quote_literal(text)}"
        end
      end
      {% for method in Model.class.methods.select { |method| method.name.starts_with?("__grant_index_") } %}
        statements.concat Model.{{method.name.id}}(Model.table_name).statements(dialect)
      {% end %}
      statements
    end

    def create(if_not_exists : Bool = false, temporary : Bool = false, comment : String? = nil)
      create_statements(if_not_exists, temporary, comment).each do |statement|
        Model.unscoped { |_scope| Model.exec statement }
      end
      Model.adapter.reset_schema_caches!(Model.table_name.rpartition('.').last)
    end

    private def dialect : Grant::Schema::Dialect
      Grant::Schema::Dialect.for(Model.adapter)
    end

    private def native_type(key : String) : String
      Grant::Schema::TypeCatalog.lookup(Model.adapter, key) ||
        raise Grant::Schema::UnsupportedOperation.new("Migrator(#{Model.adapter.class.name}) doesn't support '#{key}' yet.")
    end

    private def column_comments : Array({String, String})
      list = [] of {String, String}
      {% for ivar in Model.instance_vars.select { |iv| (a = iv.annotation(Grant::Column)) && a[:comment] } %}
        list << {"{{ivar.name}}", {{ivar.annotation(Grant::Column)[:comment]}}}
      {% end %}
      list
    end

    # The created_at/updated_at type with the `precision:` of the `timestamps`
    # macro: fractional digits on PostgreSQL and MySQL (SQLite stores text).
    private def stamped_type(type : String, precision : Int32?) : String
      return type if precision.nil? || dialect.sqlite?
      dialect.mysql? ? type.gsub("(6)", "(#{precision})") : type.sub(/\ATIMESTAMP(\(\d+\))?/i, "TIMESTAMP(#{precision})")
    end

    # One column definition line, without its trailing newline.
    private def column_line(name : String, key : String, verbatim : String?, timestamp : Bool, nilable : Bool,
                            null : Bool?, primary : Bool, limit : Int32?, precision : Int32?, scale : Int32?,
                            comment : String?, collation : String?, default_sql : String?, literal_default : String) : String
      type = if verbatim
               verbatim
             elsif timestamp
               stamped_type(native_type(name), precision)
             else
               Grant::Schema::TypeCatalog.refine(dialect, key, native_type(key), limit, precision, scale)
             end
      type += " COLLATE #{dialect.pg? ? dialect.quote(collation) : collation}" if collation && !verbatim
      not_null = if null == false
                   true
                 elsif null == true || verbatim || timestamp || nilable
                   false
                 else
                   true
                 end
      if not_null
        # MySQL's timestamp types already carry an explicit `NULL`.
        type = type.includes?(" NULL DEFAULT") ? type.sub(" NULL DEFAULT", " NOT NULL DEFAULT") : "#{type} NOT NULL"
      end
      default = default_sql ? " DEFAULT #{dialect.default_expression(default_sql, type)}" : literal_default
      line = "#{Model.adapter.quote(name)} #{type}#{default}"
      line += " COMMENT #{dialect.quote_literal(comment)}" if comment && dialect.mysql?
      line
    end
  end
end
