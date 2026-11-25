module Grant::SQLiteEngine::Query
  # PRAGMAs added for milestone G6 (pragma.html): auto_vacuum, optimize and
  # incremental_vacuum, and the table-valued form `pragma_NAME` of the
  # PRAGMAs that answer with one value ("PRAGMA functions").
  module PragmaExtras
    AUTO_VACUUM_OFFSET        = 52
    INCREMENTAL_VACUUM_OFFSET = 64

    # The table-valued PRAGMAs that take no argument, with the column each
    # returns (pragma.c aPragmaName, the entries flagged PragFlg_Result0).
    TABLE_VALUED = {
      "pragma_analysis_limit"            => %w[analysis_limit],
      "pragma_application_id"            => %w[application_id],
      "pragma_auto_vacuum"               => %w[auto_vacuum],
      "pragma_automatic_index"           => %w[automatic_index],
      "pragma_busy_timeout"              => %w[timeout],
      "pragma_cache_size"                => %w[cache_size],
      "pragma_cell_size_check"           => %w[cell_size_check],
      "pragma_checkpoint_fullfsync"      => %w[checkpoint_fullfsync],
      "pragma_defer_foreign_keys"        => %w[defer_foreign_keys],
      "pragma_encoding"                  => %w[encoding],
      "pragma_foreign_key_check"         => %w[table rowid parent fkid],
      "pragma_foreign_keys"              => %w[foreign_keys],
      "pragma_freelist_count"            => %w[freelist_count],
      "pragma_fullfsync"                 => %w[fullfsync],
      "pragma_integrity_check"           => %w[integrity_check],
      "pragma_journal_mode"              => %w[journal_mode],
      "pragma_legacy_alter_table"        => %w[legacy_alter_table],
      "pragma_max_page_count"            => %w[max_page_count],
      "pragma_optimize"                  => %w[optimize],
      "pragma_page_count"                => %w[page_count],
      "pragma_page_size"                 => %w[page_size],
      "pragma_query_only"                => %w[query_only],
      "pragma_quick_check"               => %w[quick_check],
      "pragma_recursive_triggers"        => %w[recursive_triggers],
      "pragma_reverse_unordered_selects" => %w[reverse_unordered_selects],
      "pragma_schema_version"            => %w[schema_version],
      "pragma_secure_delete"             => %w[secure_delete],
      "pragma_synchronous"               => %w[synchronous],
      "pragma_temp_store"                => %w[temp_store],
      "pragma_threads"                   => %w[threads],
      "pragma_trusted_schema"            => %w[trusted_schema],
      "pragma_user_version"              => %w[user_version],
    }

    # The column names of `PRAGMA name` for the PRAGMAs of this module, or
    # nil for another PRAGMA. auto_vacuum reports a row only when read;
    # optimize always names its column; incremental_vacuum has none.
    def self.columns(name : String, value : String?) : Array(String)?
      case name
      when "auto_vacuum"        then value ? [] of String : [name]
      when "optimize"           then [name]
      when "analysis_limit"     then [name]
      when "incremental_vacuum" then [] of String
      else                           DurabilityPragmas.columns(name, value)
      end
    end

    def self.rows(session : Session, name : String, value : String?, schema : String? = nil) : Array(Array(Value))
      case name
      when "auto_vacuum"    then auto_vacuum(session, value)
      when "optimize"       then PragmaOptimize.new(session, schema, value).rows
      when "analysis_limit" then analysis_limit(session, value)
      when DurabilityPragmas::FULLFSYNC, DurabilityPragmas::CHECKPOINT_FULLFSYNC
        DurabilityPragmas.rows(session, name, value)
      else
        # incremental_vacuum has no
        # free pages to release in a database without auto_vacuum.
        [] of Array(Value)
      end
    end

    # The rows of `pragma_NAME` read as a table.
    def self.table_valued_rows(name : String, argument : String, session : Session) : Array(Array(Value))
      return [] of Array(Value) unless TABLE_VALUED.has_key?(name)
      pragma_name = name.lchop("pragma_")
      if pragma_name == "foreign_key_check"
        return ForeignKeyCheck.new(session, argument.empty? ? nil : argument).rows
      end
      statement = SQL::Parser.parse_schema("PRAGMA #{pragma_name}").as?(SQL::Pragma)
      return [] of Array(Value) unless statement
      PragmaPlan.new(session, statement).run([] of Value)
    end

    # analysis_limit: a value of 0 or more becomes the limit; the limit is
    # returned either way.
    private def self.analysis_limit(session : Session, value : String?) : Array(Array(Value))
      if value
        text = value.strip
        number = text.to_i64? || text.lchop?("0x").try(&.to_i64?(16)) || text.lchop?("0X").try(&.to_i64?(16))
        session.pragma_values["analysis_limit"] = number & 0x7fffffff_i64 if number && number >= 0
      end
      [[session.analysis_limit] of Value]
    end

    # auto_vacuum: 0 (none), 1 (full) or 2 (incremental), from the header.
    # C changes the mode only while the database is still empty; the
    # engine writes databases without auto_vacuum, so asking for another
    # mode there is refused by name.
    private def self.auto_vacuum(session : Session, value : String?) : Array(Array(Value))
      database = session.database
      if value
        wanted = PragmaPlan.integer(value) || {"none" => 0_i64, "full" => 1_i64, "incremental" => 2_i64}[value.downcase]? || 0_i64
        if wanted.in?(1_i64, 2_i64) && database.page_count == 0
          raise UnsupportedSQL.new("PRAGMA auto_vacuum=#{value} on an empty database")
        end
        return [] of Array(Value)
      end
      return [[0_i64] of Value] if database.page_count == 0
      pager = database.pager
      mode = if pager.header_field(AUTO_VACUUM_OFFSET) == 0
               0_i64
             else
               pager.header_field(INCREMENTAL_VACUUM_OFFSET) == 0 ? 1_i64 : 2_i64
             end
      [[mode] of Value]
    end
  end

  # PRAGMA foreign_key_check (pragma.c PragTyp_FOREIGN_KEY_CHECK): one row
  # (table, rowid, parent, fkid) for each row of a child table whose
  # foreign key has no parent row. A row with a NULL in the key is never a
  # violation; a missing parent table makes every other row one. The rowid
  # is NULL for a WITHOUT ROWID table, and fkid is the key's id in
  # `PRAGMA foreign_key_list`.
  class ForeignKeyCheck
    def initialize(@session : Session, @table_name : String?)
    end

    # The column names; a named table that does not exist is refused when
    # the statement is prepared, as in C.
    def self.columns(session : Session, table_name : String?) : Array(String)
      if table_name && session.table(table_name).nil?
        raise SQLError.new("no such table: #{table_name}")
      end
      %w[table rowid parent fkid]
    end

    def rows : Array(Array(Value))
      rows = [] of Array(Value)
      run = WriteRun.new(@session, [] of Value)
      list_of_table_names.each do |name|
        table = @session.write_table(name)
        next unless table
        next if table.list_of_foreign_keys.empty?
        check_table(run, table, rows)
      end
      rows
    end

    private def list_of_table_names : Array(String)
      if name = @table_name
        raise SQLError.new("no such table: #{name}") unless @session.table(name)
        return [name]
      end
      SchemaHashOrder.new(@session.database.schema).list_of_table_names
    end

    private def check_table(run : WriteRun, table : WriteTable, rows : Array(Array(Value))) : Nil
      # C numbers a table's keys from the last one declared.
      list_of_rules = table.list_of_foreign_keys.reverse
      list_of_lookups = list_of_rules.map do |rule|
        parent = @session.write_table(rule.parent_table)
        parent ? ParentLookup.locate(run, rule, parent) : nil
      end
      run.cursor_rows(table) do |rowid, row|
        list_of_rules.each_with_index do |rule, fkid|
          values = rule.list_of_child_positions.map { |position| row[position] }
          next if values.any?(Nil)
          lookup = list_of_lookups[fkid]
          next if lookup && lookup.parent_exists?(values)
          rows << [table.table_info.name, rowid, rule.parent_table, fkid.to_i64] of Value
        end
      end
    end
  end

  # The order C walks a schema's tables in when a PRAGMA names none: the
  # order of its table hash (hash.c), which starts as a list with the
  # newest name first and becomes buckets of `strHash(name) % size` once it
  # holds five names (three buckets per name, 64 at most). The hash holds sqlite_master and every table and view.
  #
  # rehash sizes the table by what the allocator handed back
  # (sqlite3MallocSize), so the bucket count, and with it the order, follows
  # the allocator of the machine: `allocated_buckets` models the size classes
  # of the macOS allocator the pinned reference library runs on.
  class SchemaHashOrder
    private class Bucket
      property count = 0
      property chain : String?
    end

    # SQLITE_MALLOC_SOFT_LIMIT (1024 bytes) over the 16 bytes of a bucket.
    MAXIMUM_BUCKETS = 64

    def initialize(@schema : Schema)
    end

    # The buckets that fit the allocation made for *wanted* buckets of 16
    # bytes: sizes round up to a multiple of 16 bytes up to 128, of 32 up
    # to 256, of 64 up to 512 and of 128 up to 1024.
    def self.allocated_buckets(wanted : Int32) : Int32
      bytes = wanted * 16
      step = bytes <= 128 ? 16 : bytes <= 256 ? 32 : bytes <= 512 ? 64 : 128
      ((bytes + step - 1) // step * step) // 16
    end

    def list_of_table_names : Array(String)
      list_of_names = ["sqlite_master"]
      @schema.list_of_entries.each do |entry|
        list_of_names << entry.object_name if entry.object_type.in?("table", "view")
      end
      order = [] of String
      buckets = [] of Bucket
      list_of_names.each_with_index do |name, index|
        count = index + 1
        new_size = SchemaHashOrder.allocated_buckets(Math.min(count * 3, MAXIMUM_BUCKETS))
        if count >= 5 && count > 2 * buckets.size && new_size != buckets.size
          buckets = Array(Bucket).new(new_size) { Bucket.new }
          previous = order
          order = [] of String
          previous.each { |existing| insert(order, buckets, existing) }
        end
        insert(order, buckets, name)
      end
      order.reject("sqlite_master")
    end

    # hash.c insertElement: a name joins its bucket in front of the
    # bucket's newest name, or the front of the list for an empty bucket.
    private def insert(order : Array(String), buckets : Array(Bucket), name : String) : Nil
      if buckets.empty?
        order.unshift(name)
        return
      end
      bucket = buckets[hash_of(name) % buckets.size]
      head = bucket.count > 0 ? bucket.chain : nil
      bucket.count += 1
      bucket.chain = name
      position = head ? order.index(head) : nil
      order.insert(position || 0, name)
    end

    # hash.c strHash: Knuth multiplicative hashing over the bytes with the
    # case bit cleared.
    private def hash_of(name : String) : UInt32
      hash = 0_u32
      name.each_byte do |byte|
        hash &+= (byte & 0xdf_u8).to_u32
        hash &*= 0x9e3779b1_u32
      end
      hash
    end
  end
end
