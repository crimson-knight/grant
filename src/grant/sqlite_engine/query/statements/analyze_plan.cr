module Grant::SQLiteEngine
  class Database
    # Adds `sqlite_stat1` to the schema as ANALYZE does; a statement may not
    # create a table of that reserved name.
    def create_statistics_table : Nil
      write_statement do
        writer = btree_writer
        root = writer.create_tree(table: true)
        name = Query::AnalyzePlan::STATISTICS_TABLE
        insert_schema_row(writer, "table", name, name, root, Query::AnalyzePlan::STATISTICS_TABLE_SQL)
        schema_changed
      end
    end
  end
end

module Grant::SQLiteEngine::Query
  class Session
    # The statistics the planner and PRAGMA optimize read, loaded from
    # sqlite_stat1 on first use and again after ANALYZE or a schema change.
    @statistics : PlannerStatistics? = nil
    @carried_table_estimates : Hash(String, Int16)? = nil

    def statistics : PlannerStatistics
      @statistics ||= PlannerStatistics.load(self, @carried_table_estimates)
    end

    def reset_schema : Nil
      previous_def
      if statistics = @statistics
        @carried_table_estimates = statistics.table_estimates
        @statistics = nil
      end
    end

    # PRAGMA analysis_limit: the most index entries ANALYZE reads per index
    # (0 reads them all).
    def analysis_limit : Int64
      pragma_values["analysis_limit"]?.as?(Int64) || 0_i64
    end
  end

  # ANALYZE (lang_analyze.html, analyze.c): gathers `sqlite_stat1` rows for
  # every index of the analyzed tables. The whole database, one schema, one
  # table or one index is analyzed; `sqlite_stat1(tbl,idx,stat)` is created
  # when the schema lacks it, the rows of the analyzed objects are replaced
  # and the new rows are appended in the order C writes them.
  class AnalyzePlan < StatementPlan
    STATISTICS_TABLE     = "sqlite_stat1"
    STATISTICS_TABLE_SQL = "CREATE TABLE sqlite_stat1(tbl,idx,stat)"

    # What one ANALYZE covers in one schema: every table (no names), one
    # table, or one index of a table.
    record Target, database : Database, schema_name : String, table_name : String?, index_name : String?

    def initialize(@session : Session, @statement : SQL::Analyze)
      list_of_targets
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      AnalyzePlan.perform(@session, list_of_targets, @session.analysis_limit, list_of_parameters)
      [] of Array(Value)
    end

    # Analyzes *list_of_targets* in one write statement. changes(),
    # total_changes() and last_insert_rowid() stay as they were: C writes
    # the statistics rows without counting them.
    def self.perform(session : Session, list_of_targets : Array(Target), limit : Int64,
                     list_of_parameters : Array(Value) = [] of Value) : Nil
      changes = session.changes
      total_changes = session.total_changes
      last_insert_rowid = session.last_insert_rowid
      # The estimates read before this ANALYZE stay for the tables it
      # leaves without rows.
      session.statistics
      begin
        session.run_write(list_of_parameters, counts_changes: false) do |run|
          list_of_targets.each { |target| GatherStatisticsForAnalyze.new(session, run, target, limit).perform }
        end
      ensure
        session.changes = changes
        session.total_changes = total_changes
        session.last_insert_rowid = last_insert_rowid
        session.reset_schema
      end
    end

    # sqlite3Analyze: no name analyzes every schema but temp; a lone name
    # is a schema when one has it, else an index, else a table.
    private def list_of_targets : Array(Target)
      name = @statement.name
      schema = @statement.schema
      unless name
        return @session.list_of_databases.compact_map do |database|
          next if database.same?(@session.temp_database)
          Target.new(database, @session.schema_name_of(database), nil, nil)
        end
      end
      if schema.nil? && @session.schema?(name.value)
        database = @session.database_named(name.value)
        return [] of Target unless database
        return [Target.new(database, @session.schema_name_of(database), nil, nil)]
      end
      if schema && !@session.schema?(schema.value)
        raise SQLError.new("unknown database #{schema.value}")
      end
      list_of_candidates = [] of Database
      if schema
        named = @session.database_named(schema.value)
        list_of_candidates << named if named
      else
        @session.each_database_in_search_order { |database| list_of_candidates << database }
      end
      list_of_candidates.each do |database|
        next if database.page_count == 0
        index = database.schema.list_of_indexes.find { |entry| entry.object_name.compare(name.value, case_insensitive: true) == 0 }
        next unless index
        return [Target.new(database, @session.schema_name_of(database), index.table_name, index.object_name)]
      end
      table_info = @session.table(name.value, schema.try(&.value))
      # A view is found and carries no statistics.
      if table_info.nil? && (view = @session.view(name.value))
        return [Target.new(@session.database, @session.schema_name_of(@session.database), name.value, nil)]
      end
      unless table_info
        raise SQLError.new("no such table: #{schema ? "#{schema.value}." : ""}#{name.value}")
      end
      [Target.new(table_info.database, @session.schema_name_of(table_info.database), table_info.name, nil)]
    end
  end

  # Writes the sqlite_stat1 rows of one ANALYZE target (analyzeDatabase and
  # analyzeTable).
  class GatherStatisticsForAnalyze
    def initialize(@session : Session, @run : WriteRun, @target : AnalyzePlan::Target, @limit : Int64)
    end

    def perform : Nil
      # C lists the tables when it compiles the statement, before the
      # statement adds sqlite_stat1 to the schema.
      list_of_names = list_of_table_names
      statistics_table = open_statistics_table
      list_of_names.each do |name|
        table = @session.write_table(name, @target.schema_name)
        next unless table
        analyze_table(statistics_table, table)
      end
    end

    # openStatTable: creates sqlite_stat1, or removes the rows of the
    # analyzed table or index (every row for a whole schema).
    private def open_statistics_table : WriteTable
      schema_name = @target.schema_name
      existing = @session.write_table(AnalyzePlan::STATISTICS_TABLE, schema_name)
      unless existing
        @target.database.create_statistics_table
        @session.reset_schema
        return @run.table(AnalyzePlan::STATISTICS_TABLE, schema_name)
      end
      column, wanted = if index_name = @target.index_name
                         {1, index_name}
                       else
                         {0, @target.table_name}
                       end
      list_of_old_rows = [] of {Int64?, Array(Value)}
      @run.cursor_rows(existing) do |rowid, row|
        list_of_old_rows << {rowid, row} if wanted.nil? || row[column]? == wanted
      end
      list_of_old_rows.each { |rowid, row| @run.delete_row(existing, rowid, row) }
      existing
    end

    # The tables to analyze: the named one, or the schema's ordinary tables
    # in the order of C's table hash. System tables (`sqlite_...`) and views
    # carry no statistics.
    private def list_of_table_names : Array(String)
      database = @target.database
      return [] of String if database.page_count == 0
      list_of_names = if name = @target.table_name
                        [name]
                      else
                        SchemaHashOrder.new(database.schema).list_of_table_names
                      end
      list_of_names.select do |name|
        entry = database.schema.list_of_tables.find { |candidate| candidate.object_name == name }
        !entry.nil? && entry.has_a_btree? && !name.downcase.starts_with?("sqlite_")
      end
    end

    # analyzeOneTable: one row per index, in the order of the table's index
    # list; a table none of whose analyzed indexes covers every row gets a
    # row with a NULL index holding its row count, unless it is empty.
    private def analyze_table(statistics_table : WriteTable, table : WriteTable) : Nil
      only_index = @target.index_name
      needs_table_count = true
      table.list_of_rules_in_check_order.each do |rule|
        accumulator = if rule
                        layout = rule.layout
                        next if only_index && layout.entry.object_name != only_index
                        needs_table_count = false unless layout.partial?
                        index_statistics(table, rule)
                      else
                        next if only_index
                        needs_table_count = false
                        primary_key_statistics(table)
                      end
        partial = rule.try(&.layout.partial?) || false
        next if accumulator.row_count == 0 && !partial
        name = rule ? rule.layout.entry.object_name : table.name
        write_row(statistics_table, table.name, name, accumulator.text)
      end
      return if only_index || !needs_table_count
      count = 0_i64
      @run.cursor_rows(table) { count += 1 }
      write_row(statistics_table, table.name, nil, count.to_s) if count > 0
    end

    private def write_row(statistics_table : WriteTable, table_name : String, index_name : String?, text : String) : Nil
      @run.insert_row(statistics_table, [table_name, index_name, text] of Value, nil, ConflictAction::Default)
    end

    # An index's entries are its key columns followed by the rowid (or the
    # primary key columns the key lacks). A UNIQUE index over NOT NULL
    # columns compares all but its last key column; any other index
    # compares all but its last entry column.
    private def index_statistics(table : WriteTable, rule : IndexRule) : StatisticsAccumulator
      layout = rule.layout
      list_of_collations = layout.comparator.list_of_key_columns.map(&.collation)
      entry_width = layout.key_count + Math.max(layout.list_of_tail_positions.size, 1)
      compared = unique_and_not_null?(table, layout) ? layout.key_count - 1 : entry_width - 1
      database = table.database
      total = 0_i64
      database.each_index_entry(layout.entry) { total += 1 } if @limit > 0
      accumulator = StatisticsAccumulator.new(layout.key_count, compared, list_of_collations, layout.comparator, @limit, total)
      database.each_index_entry(layout.entry) do |entry|
        break unless accumulator.push(entry)
      end
      accumulator
    end

    # The PRIMARY KEY of a WITHOUT ROWID table is the table's own b-tree:
    # its key columns are the entry, all but the last compared.
    private def primary_key_statistics(table : WriteTable) : StatisticsAccumulator
      list_of_keys = IndexLayout.primary_key_columns(table.definition)
      list_of_positions = list_of_keys.map(&.[0])
      list_of_key_columns = list_of_keys.map(&.[1])
      comparator = KeyComparator.new(list_of_key_columns, table.database.text_encoding)
      total = 0_i64
      @run.cursor_rows(table) { total += 1 } if @limit > 0
      accumulator = StatisticsAccumulator.new(list_of_positions.size, list_of_positions.size - 1,
        list_of_key_columns.map(&.collation), comparator, @limit, total)
      @run.cursor_rows(table) do |_rowid, row|
        break unless accumulator.push(list_of_positions.map { |position| row[position] })
      end
      accumulator
    end

    # Index.uniqNotNull: a UNIQUE index whose key columns are all plain
    # columns declared NOT NULL.
    private def unique_and_not_null?(table : WriteTable, layout : IndexLayout) : Bool
      return false unless layout.unique? && !layout.has_expressions?
      layout.list_of_key_positions.all? { |position| !table.list_of_columns[position].not_null.nil? }
    end
  end

  # stat_init, stat_push and stat_get of analyze.c without STAT4: counts
  # the entries of an index and, for each prefix of its key, how many
  # times the prefix changed from one entry to the next.
  class StatisticsAccumulator
    getter row_count = 0_i64

    @skip_ahead = 0_i64
    @seeking = false
    @list_of_previous : Array(Value)
    @list_of_changes : Array(Int64)

    def initialize(@key_count : Int32, @compared : Int32, @list_of_collations : Array(Collation), @comparator : KeyComparator,
                   @limit : Int64, @total : Int64)
      @list_of_previous = Array(Value).new(Math.max(@compared, 0), nil)
      @list_of_changes = Array(Int64).new(@key_count, 0_i64)
    end

    # Takes the next entry in key order; false once no more are wanted.
    # With an analysis limit, an index whose first column has not changed
    # within the limit skips to the entry after the next first-column
    # value (OP_SeekGT then OP_Next), and one whose first column has
    # changed stops.
    def push(entry : Array(Value)) : Bool
      if @seeking
        return true if same?(entry, 0)
        @seeking = false
        return true
      end
      changed = 0
      if @row_count > 0
        while changed < @compared && same?(entry, changed)
          changed += 1
        end
        (changed...@key_count).each { |index| @list_of_changes[index] += 1 }
      end
      (changed...@compared).each { |index| @list_of_previous[index] = entry[index] }
      @row_count += 1
      if @limit > 0 && @row_count > @limit * (@skip_ahead + 1)
        @skip_ahead += 1
        return false if @list_of_changes[0] > 0
        @seeking = true
      end
      true
    end

    private def same?(entry : Array(Value), index : Int32) : Bool
      collation = @list_of_collations[index]? || Collation::Binary
      @comparator.compare_values(entry[index], @list_of_previous[index], collation) == 0
    end

    # The `stat` text: the entry count, then for each key prefix the
    # entries per distinct prefix rounded up, kept at 1 when under 1.1.
    def text : String
      String.build do |io|
        io << (@skip_ahead > 0 ? @total : @row_count)
        @list_of_changes.each do |changes|
          distinct = changes + 1
          average = (@row_count + distinct - 1) // distinct
          average = 1_i64 if average == 2 && @row_count * 10 <= distinct * 11
          io << ' ' << average
        end
      end
    end
  end
end
