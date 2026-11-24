module Grant::SQLiteEngine::Query
  class Session
    # The tables a query of this connection read through an index in a way
    # statistics decide (TF_MaybeReanalyze), as schema and table name keys.
    getter list_of_tables_to_reanalyze = Set(String).new

    # whereLoopAddBtree: a query whose terms fix or bound the leading
    # columns of *layout* without completing a UNIQUE key is one that
    # statistics decide, so PRAGMA optimize looks at its table.
    def note_statistics_use(table : TableInfo, layout : IndexLayout, equal_count : Int32, ranged : Bool) : Nil
      return if equal_count == 0 && !ranged
      used_count = equal_count + (ranged ? 1 : 0)
      return if layout.unique? && used_count >= layout.key_count
      @list_of_tables_to_reanalyze << PlannerStatistics.key(schema_name_of(table.database), table.name)
    end
  end

  # PRAGMA optimize (pragma.c PragTyp_OPTIMIZE): runs ANALYZE on the tables
  # that might gain from it. A table is looked at when a query used one of
  # its indexes in a way statistics decide, when mask bit 0x10000 is set,
  # or when one of its indexes has no statistics; it is analyzed when an
  # index has no statistics and the table has rows, or when its size left
  # the range of a tenth to ten times the size in sqlite_stat1. Mask bit
  # 0x01 returns the ANALYZE statements instead of running them.
  class PragmaOptimize
    DEFAULT_MASK  = 0xfffe_i64
    DEFAULT_LIMIT =   2000_i64
    # A tenfold change of size as a LogEst.
    SIZE_RANGE = 33

    record Candidate, database : Database, schema_name : String, table : WriteTable, threshold : Int32

    def initialize(@session : Session, @schema : String?, value : String?)
      @mask = value ? PragmaOptimize.integer_prefix(value) : DEFAULT_MASK
      @runs = value.nil? || (@mask & 0x02) != 0
    end

    def rows : Array(Array(Value))
      rows = [] of Array(Value)
      return rows unless @runs
      list_of_candidates = list_of_candidates()
      btree_count = list_of_candidates.sum { |candidate| candidate.table.list_of_rules_in_check_order.size + 1 }
      limit = analysis_limit(btree_count)
      list_of_candidates.each do |candidate|
        next unless size_changed?(candidate)
        table_name = candidate.table.name
        if (@mask & 0x01) != 0
          rows << [%(ANALYZE "#{quoted(candidate.schema_name)}"."#{quoted(table_name)}")] of Value
        else
          target = AnalyzePlan::Target.new(candidate.database, candidate.schema_name, table_name, nil)
          AnalyzePlan.perform(@session, [target], limit)
        end
      end
      rows
    end

    # sqlite3Atoi: the leading decimal or hexadecimal integer, else 0.
    def self.integer_prefix(text : String) : Int64
      text = text.strip
      if match = text.match(/\A0[xX]([0-9a-fA-F]+)/)
        return match[1].to_u64?(16).try(&.to_i64!) || 0_i64
      end
      match = text.match(/\A[+-]?\d+/)
      number = match ? match[0].to_i64? : nil
      (number || 0_i64).clamp(Int32::MIN.to_i64, Int32::MAX.to_i64)
    end

    private def quoted(name : String) : String
      name.gsub('"', "\"\"")
    end

    # Mask bit 0x10 analyzes with a limit of 2000 entries per index unless
    # the connection's own analysis_limit is lower; a schema of more than a
    # hundred b-trees scales that down, to 100 at least.
    private def analysis_limit(btree_count : Int32) : Int64
      own = @session.analysis_limit
      return own if (@mask & 0x10) == 0 || (own > 0 && own < DEFAULT_LIMIT)
      limit = DEFAULT_LIMIT
      limit = Math.max(100_i64 * limit // btree_count, 100_i64) if btree_count > 100
      limit
    end

    private def list_of_candidates : Array(Candidate)
      list = [] of Candidate
      statistics = @session.statistics
      list_of_databases.each do |database|
        next if database.page_count == 0 || database.same?(@session.temp_database)
        schema_name = @session.schema_name_of(database)
        SchemaHashOrder.new(database.schema).list_of_table_names.each do |name|
          next if name.downcase.starts_with?("sqlite_")
          entry = database.schema.list_of_tables.find { |candidate| candidate.object_name == name }
          next unless entry && entry.has_a_btree?
          table = @session.write_table(name, schema_name)
          next unless table
          threshold = statistics.table_estimate(schema_name, name).to_i32
          list_of_rules = table.list_of_rules_in_check_order
          lacks_statistics = list_of_rules.any? do |rule|
            statistics.index_estimate(schema_name, rule ? rule.layout.entry.object_name : name).nil?
          end
          threshold = -1 if lacks_statistics
          used = @session.list_of_tables_to_reanalyze.includes?(PlannerStatistics.key(schema_name, name))
          rules_ask_for_it = !list_of_rules.empty? && threshold < 0
          next unless used || (@mask & 0x10000) != 0 || rules_ask_for_it
          list << Candidate.new(database, schema_name, table, threshold)
        end
      end
      list
    end

    private def list_of_databases : Array(Database)
      if schema = @schema
        named = @session.database_named(schema)
        return named ? [named] : [] of Database
      end
      @session.list_of_databases
    end

    # OP_IfSizeBetween and OP_Rewind: an unanalyzed table is analyzed
    # unless it is empty; an analyzed one when the size its b-tree's shape
    # suggests left the range around the recorded size.
    private def size_changed?(candidate : Candidate) : Bool
      size = estimated_size(candidate.table)
      threshold = candidate.threshold
      return size >= 0 if threshold < 0
      low = threshold >= SIZE_RANGE ? threshold - SIZE_RANGE : -1
      !(size >= low && size <= threshold + SIZE_RANGE)
    end

    # sqlite3BtreeRowCountEst as a LogEst: the cells of the first leaf
    # times the fan-out of each page above it; -1 for an empty table.
    private def estimated_size(table : WriteTable) : Int32
      pager = table.database.pager
      page = BTreePage.read(pager, table.table_info.root_page)
      fan_out = 1_u64
      while page.page_type.interior?
        fan_out &*= (page.cell_count + 1).to_u64
        child = page.cell_count > 0 ? page.left_child(0) : page.right_child
        page = BTreePage.read(pager, child)
      end
      return -1 if page.cell_count == 0
      PlannerStatistics.log_estimate(fan_out &* page.cell_count.to_u64).to_i32
    end
  end
end
