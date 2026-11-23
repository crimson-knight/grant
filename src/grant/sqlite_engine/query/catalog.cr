module Grant::SQLiteEngine::Query
  # The PRAGMA table-valued functions Grant's catalog queries read
  # (pragma.html, "PRAGMA functions"): pragma_table_info,
  # pragma_table_xinfo, pragma_index_list, pragma_index_info,
  # pragma_index_xinfo, pragma_foreign_key_list and pragma_database_list,
  # with the rows pragma.c
  # of SQLite 3.51.0 produces.
  module Catalog
    COLUMNS = {
      "pragma_table_info"       => %w[cid name type notnull dflt_value pk],
      "pragma_table_xinfo"      => %w[cid name type notnull dflt_value pk hidden],
      "pragma_index_list"       => %w[seq name unique origin partial],
      "pragma_index_info"       => %w[seqno cid name],
      "pragma_index_xinfo"      => %w[seqno cid name desc coll key],
      "pragma_foreign_key_list" => %w[id seq table from to on_update on_delete match],
      "pragma_database_list"    => %w[seq name file],
    }

    def self.function_columns(name : String) : Array(String)
      COLUMNS[name]? || [] of String
    end

    def self.function_producer(name : String, arguments : Array(Expr), session : Session) : Producer?
      return unless COLUMNS.has_key?(name)
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
        [[0_i64, "main", session.database.file_name] of Value]
      else
        [] of Array(Value)
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
        not_null = column.constraints.any?(SQL::NotNullConstraint) ? 1_i64 : 0_i64
        default = column.constraints.compact_map(&.as?(SQL::DefaultConstraint)).first?
        default_text = hidden >= 2 || default.nil? ? nil : default.value.to_sql
        type_text = column.type_name.try { |type_name| type_text(type_name) } || ""
        row = [(index - hidden_count).to_i64, column.name.value, type_text, not_null, default_text, pk] of Value
        row << hidden if extended
        rows << row
      end
      rows
    end

    private def self.type_text(type_name : SQL::TypeName) : String
      if source_text = type_name.source_text
        return source_text
      end
      words = type_name.words.map(&.text).join(' ')
      return words if type_name.arguments.empty?
      "#{words}(#{type_name.arguments.join(',')})"
    end

    private def self.indexes_of(table : TableInfo, session : Session) : Array(SchemaEntry)
      session.database.schema.list_of_indexes.select do |entry|
        entry.table_name.compare(table.name, case_insensitive: true) == 0
      end.reverse!
    end

    private def self.index_list(name : String, session : Session) : Array(Array(Value))
      table = session.table(name)
      return [] of Array(Value) unless table
      indexes_of(table, session).map_with_index do |entry, position|
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
        [position.to_i64, entry.object_name, unique, origin, partial] of Value
      end
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
      # pragma_database_list takes no argument; the others yield no rows
      # without one.
      argument = "" if @name == "pragma_database_list"
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
