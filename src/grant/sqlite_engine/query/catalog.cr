module Grant::SQLiteEngine::Query
  # The PRAGMA table-valued functions Grant's catalog queries read
  # (pragma.html, "PRAGMA functions"): pragma_table_info,
  # pragma_table_xinfo, pragma_index_list, pragma_index_info,
  # pragma_index_xinfo, pragma_foreign_key_list, pragma_database_list and
  # pragma_table_list, with the rows pragma.c of SQLite 3.51.0 produces.
  module Catalog
    COLUMNS = {
      "pragma_table_info"       => %w[cid name type notnull dflt_value pk],
      "pragma_table_xinfo"      => %w[cid name type notnull dflt_value pk hidden],
      "pragma_index_list"       => %w[seq name unique origin partial],
      "pragma_index_info"       => %w[seqno cid name],
      "pragma_index_xinfo"      => %w[seqno cid name desc coll key],
      "pragma_foreign_key_list" => %w[id seq table from to on_update on_delete match],
      "pragma_database_list"    => %w[seq name file],
      "pragma_table_list"       => %w[schema name type ncol wr strict],
    }

    # Whether *name* is a table-valued PRAGMA.
    def self.known?(name : String) : Bool
      COLUMNS.has_key?(name) || PragmaExtras::TABLE_VALUED.has_key?(name)
    end

    def self.function_columns(name : String) : Array(String)
      COLUMNS[name]? || PragmaExtras::TABLE_VALUED[name]? || [] of String
    end

    def self.function_producer(name : String, arguments : Array(Expr), session : Session) : Producer?
      return unless known?(name)
      CatalogProducer.new(name, arguments, session)
    end

    # The rows of one function for one argument.
    def self.rows(name : String, argument : String, session : Session) : Array(Array(Value))
      case name
      when "pragma_table_info", "pragma_table_xinfo"
        table_info(argument, session, extended: name == "pragma_table_xinfo")
      when "pragma_index_list"
        index_list(argument, session)
      when "pragma_index_info", "pragma_index_xinfo"
        index_info(argument, session, extended: name == "pragma_index_xinfo")
      when "pragma_foreign_key_list"
        foreign_key_list(argument, session)
      when "pragma_database_list"
        session.database_list_rows
      when "pragma_table_list"
        table_list(argument.empty? ? nil : argument, session)
      else
        PragmaExtras.table_valued_rows(name, argument, session)
      end
    end

    private def self.create_table(table : TableInfo) : SQL::CreateTable?
      sql = table.entry.sql
      return unless sql
      SQL::Parser.parse_schema(sql).as?(SQL::CreateTable)
    end

    private def self.table_info(name : String, session : Session, extended : Bool) : Array(Array(Value))
      table = session.table(name)
      return [] of Array(Value) unless table
      syntax = create_table(table)
      return [] of Array(Value) unless syntax
      definition = table.definition
      primary_key = definition.list_of_primary_key_columns.map(&.downcase)
      rows = [] of Array(Value)
      hidden_count = 0
      syntax.columns.each_with_index do |column, index|
        generated = column.constraints.compact_map(&.as?(SQL::GeneratedConstraint)).first?
        hidden = 0_i64
        if generated
          unless extended
            hidden_count += 1
            next
          end
          storage = generated.storage.try(&.value.upcase)
          hidden = storage == "STORED" ? 3_i64 : 2_i64
        end
        position = primary_key.index(column.name.value.downcase)
        pk = position ? (position + 1).to_i64 : 0_i64
        # build.c: a PRIMARY KEY column of a WITHOUT ROWID or STRICT table
        # (not the rowid alias) is NOT NULL even when it does not say so.
        implied = pk > 0 && (definition.without_rowid? || definition.strict?) && table.rowid_alias != index
        not_null = column.constraints.any?(SQL::NotNullConstraint) || implied ? 1_i64 : 0_i64
        default = column.constraints.compact_map(&.as?(SQL::DefaultConstraint)).first?
        default_text = hidden >= 2 || default.nil? ? nil : default.value.to_sql
        type_text = column.type_name.try { |type_name| type_text(type_name) } || ""
        row = [(index - hidden_count).to_i64, column.name.value, type_text, not_null, default_text, pk] of Value
        row << hidden if extended
        rows << row
      end
      rows
    end

    # pragma.c PragTyp_TABLE_LIST: each table and view of main, temp and
    # the attached schemas (only those named *name*, and only *schema* when
    # given), with each schema table, as schema, name, kind, column count,
    # WITHOUT ROWID and STRICT. C lists a schema in its table hash order;
    # the engine lists it in sqlite_schema order, then the schema table.
    def self.table_list(name : String?, session : Session, schema : String? = nil) : Array(Array(Value))
      rows = [] of Array(Value)
      main = session.database
      temp = session.list_of_databases.find { |database| session.schema_name_of(database) == "temp" }
      attached = session.list_of_databases.reject { |database| database.same?(main) || database.same?(temp) }
      list = [{"main", main}, {"temp", temp}] of {String, Database?}
      attached.each { |database| list << {session.schema_name_of(database), database} }
      list.each do |(schema_name, database)|
        next if schema && schema.compare(schema_name, case_insensitive: true) != 0
        if database && database.page_count > 0
          database.schema.list_of_entries.each do |entry|
            next unless entry.table? || entry.object_type == "view"
            next if name && name.compare(entry.object_name, case_insensitive: true) != 0
            if row = table_list_row(schema_name, entry, session)
              rows << row
            end
          end
        end
        schema_table = schema_name == "temp" ? "sqlite_temp_schema" : "sqlite_schema"
        next if name && name.compare(schema_table, case_insensitive: true) != 0
        rows << [schema_name, schema_table, "table", 5_i64, 0_i64, 0_i64] of Value
      end
      rows
    end

    private def self.table_list_row(schema_name : String, entry : SchemaEntry, session : Session) : Array(Value)?
      if entry.object_type == "view"
        return [schema_name, entry.object_name, "view", view_column_count(schema_name, entry.object_name, session), 0_i64, 0_i64] of Value
      end
      return unless entry.has_a_btree?
      table = session.table(entry.object_name, schema_name)
      return unless table
      [schema_name, table.name, "table", table.list_of_column_names.size.to_i64,
       table.without_rowid? ? 1_i64 : 0_i64, table.definition.strict? ? 1_i64 : 0_i64] of Value
    end

    # The number of columns a view yields (sqlite3ViewGetColumnNames).
    private def self.view_column_count(schema_name : String, name : String, session : Session) : Int64
      session.prepare("SELECT * FROM #{quoted_name(schema_name)}.#{quoted_name(name)}").list_of_column_names.size.to_i64
    rescue SQLError
      0_i64
    end

    private def self.quoted_name(name : String) : String
      "\"" + name.gsub("\"", "\"\"") + "\""
    end

    # build.c sqlite3AddColumn: a declared type that is exactly one of the
    # standard type names, in any case, is kept as that name (upper case).
    STANDARD_TYPES = %w[ANY BLOB INT INTEGER REAL TEXT]

    private def self.type_text(type_name : SQL::TypeName) : String
      text = without_generated_always(full_type_text(type_name))
      STANDARD_TYPES.find { |standard| standard.compare(text, case_insensitive: true) == 0 } || text
    end

    private def self.full_type_text(type_name : SQL::TypeName) : String
      if source_text = type_name.source_text
        return source_text
      end
      words = type_name.words.map(&.text).join(' ')
      return words if type_name.arguments.empty?
      "#{words}(#{type_name.arguments.join(',')})"
    end

    # build.c sqlite3AddColumn: a declared type of 16 bytes or more that
    # ends in GENERATED ALWAYS loses those words.
    private def self.without_generated_always(text : String) : String
      return text unless text.bytesize >= 16 && text[-6..].compare("always", case_insensitive: true) == 0
      trimmed = text[0...-6].rstrip
      return trimmed unless trimmed.bytesize >= 9 && trimmed[-9..].compare("generated", case_insensitive: true) == 0
      trimmed[0...-9].rstrip
    end

    private def self.indexes_of(table : TableInfo, session : Session) : Array(SchemaEntry)
      table.database.schema.list_of_indexes.select do |entry|
        entry.table_name.compare(table.name, case_insensitive: true) == 0
      end
    end

    # One row of index_list before its position is known: name, unique,
    # origin, partial, and whether its conflict action is REPLACE.
    private record IndexListItem, index_name : String, unique : Int64, origin : String, partial : Int64, replace : Bool

    # pragma.c PragTyp_INDEX_LIST walks the table's index list as
    # sqlite3CreateIndex builds it: each new index linked at the head
    # (autoindexes as CREATE TABLE makes them, then each CREATE INDEX),
    # REPLACE indexes moved to the end. A WITHOUT ROWID table's PRIMARY
    # KEY index, which has no sqlite_schema row, is listed too.
    private def self.index_list(name : String, session : Session) : Array(Array(Value))
      table = session.table(name)
      return [] of Array(Value) unless table
      rules = session.write_table(table.name, session.schema_name_of(table.database))
      replacing = Set(String).new
      if rules
        rules.list_of_indexes.each { |rule| replacing << rule.layout.entry.object_name if rule.conflict.replace? }
      end
      entries = indexes_of(table, session)
      items = entries.map do |entry|
        layout = table.list_of_indexes.find { |candidate| candidate.entry.object_name == entry.object_name }
        origin = if entry.sql
                   "c"
                 elsif layout && layout.primary_key?
                   "pk"
                 else
                   "u"
                 end
        unique = layout ? (layout.unique? ? 1_i64 : 0_i64) : 0_i64
        partial = (sql = entry.sql) && IndexDefinition.parse(sql).partial? ? 1_i64 : 0_i64
        IndexListItem.new(entry.object_name, unique, origin, partial, replacing.includes?(entry.object_name))
      end
      if table.without_rowid? && rules
        add_without_rowid_key(items, table, rules.primary_key_conflict.replace?)
      end
      items.reverse!
      ordered = items.reject(&.replace) + items.select(&.replace)
      ordered.map_with_index do |item, position|
        [position.to_i64, item.index_name, item.unique, item.origin, item.partial] of Value
      end
    end

    # The PRIMARY KEY index of a WITHOUT ROWID table takes the autoindex
    # number the stored autoindexes leave free, and its place among them.
    private def self.add_without_rowid_key(items : Array(IndexListItem), table : TableInfo, replace : Bool) : Nil
      prefix = "sqlite_autoindex_#{table.name}_"
      numbers = items.compact_map do |item|
        item.index_name.starts_with?(prefix) ? item.index_name[prefix.size..].to_i? : nil
      end
      number = (1..numbers.size + 1).find { |candidate| !numbers.includes?(candidate) } || numbers.size + 1
      key = IndexListItem.new("#{prefix}#{number}", 1_i64, "pk", 0_i64, replace)
      position = items.index do |item|
        later = item.index_name.starts_with?(prefix) && (item.index_name[prefix.size..].to_i? || 0) > number
        later || item.origin == "c"
      end
      items.insert(position || items.size, key)
    end

    private def self.index_info(name : String, session : Session, extended : Bool) : Array(Array(Value))
      layout = session.index_layout(name)
      return [] of Array(Value) unless layout
      table = session.table(layout.entry.table_name)
      return [] of Array(Value) unless table
      rows = [] of Array(Value)
      key_columns = layout.comparator.list_of_key_columns
      layout.list_of_key_positions.each_with_index do |position, key_index|
        expression = position == IndexLayout::EXPRESSION
        column_number = position.to_i64
        column_name = expression ? nil : table.list_of_column_names[position]
        row = [key_index.to_i64, column_number, column_name] of Value
        if extended
          key = key_columns[key_index]
          row << (key.descending ? 1_i64 : 0_i64) << key.collation.to_s.upcase << 1_i64
        end
        rows << row
      end
      return rows unless extended
      sequence = layout.key_count
      layout.list_of_tail_positions.each_with_index do |position, tail_index|
        key = key_columns[layout.key_count + tail_index]? || KeyColumn.new(Collation::Binary, false)
        rows << [sequence.to_i64, position.to_i64, table.list_of_column_names[position],
                 key.descending ? 1_i64 : 0_i64, key.collation.to_s.upcase, 0_i64] of Value
        sequence += 1
      end
      unless table.without_rowid?
        rows << [sequence.to_i64, -1_i64, nil, 0_i64, "BINARY", 0_i64] of Value
      end
      rows
    end

    private def self.foreign_key_list(name : String, session : Session) : Array(Array(Value))
      table = session.table(name)
      return [] of Array(Value) unless table
      syntax = create_table(table)
      return [] of Array(Value) unless syntax
      keys = [] of {Array(String), SQL::ForeignKeyClause}
      syntax.columns.each do |column|
        column.constraints.each do |constraint|
          keys << {[column.name.value], constraint.clause} if constraint.is_a?(SQL::ReferencesConstraint)
        end
      end
      syntax.constraints.each do |constraint|
        keys << {constraint.columns.map(&.value), constraint.clause} if constraint.is_a?(SQL::ForeignKeyTableConstraint)
      end
      rows = [] of Array(Value)
      keys.reverse.each_with_index do |(from_columns, clause), id|
        on_update = action_name(clause, "UPDATE")
        on_delete = action_name(clause, "DELETE")
        from_columns.each_with_index do |from, sequence|
          to = clause.columns.try { |columns| columns[sequence]?.try(&.value) }
          declared = table.column_index(from).try { |column_index| table.list_of_column_names[column_index] } || from
          rows << [id.to_i64, sequence.to_i64, clause.table.value, declared, to, on_update, on_delete, "NONE"] of Value
        end
      end
      rows
    end

    private def self.action_name(clause : SQL::ForeignKeyClause, event : String) : String
      action = clause.actions.reverse.find { |candidate| candidate.event.upcase == event }
      return "NO ACTION" unless action
      case action.action.upcase
      when "SET NULL"    then "SET NULL"
      when "SET DEFAULT" then "SET DEFAULT"
      when "CASCADE"     then "CASCADE"
      when "RESTRICT"    then "RESTRICT"
      else                    "NO ACTION"
      end
    end
  end

  # Rows of a PRAGMA function for the argument value of the current row.
  class CatalogProducer < Producer
    @rows = [] of Array(Value)
    @position = 0

    def initialize(@name : String, @list_of_arguments : Array(Expr), @session : Session)
    end

    def open(frame : Frame) : Nil
      first = @list_of_arguments.first?
      argument = first ? ValueSemantics.text(first.evaluate(frame)) : nil
      # pragma_database_list takes no argument and pragma_table_list lists
      # every table without one; the others yield no rows without one.
      argument = "" if @name == "pragma_database_list"
      argument ||= "" if @name == "pragma_table_list"
      argument ||= "" if PragmaExtras::TABLE_VALUED.has_key?(@name)
      @rows = argument ? Catalog.rows(@name, argument, @session) : [] of Array(Value)
      @position = 0
    end

    def next_row(frame : Frame) : Array(Value)?
      return if @position >= @rows.size
      row = @rows[@position]
      @position += 1
      row
    end
  end
end
