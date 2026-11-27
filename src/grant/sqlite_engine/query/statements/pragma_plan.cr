module Grant::SQLiteEngine::Query
  # The PRAGMAs Grant, micrate and the Amber CLI send (pragma.html), with
  # the rows and column names pragma.c returns. A PRAGMA C does not know
  # does nothing and returns no rows, as in C.
  class PragmaPlan < StatementPlan
    USER_VERSION_OFFSET   = 60
    APPLICATION_ID_OFFSET = 68

    # PRAGMAs that only report a value the engine keeps for the session,
    # with C's default and the column name of the row they return.
    REMEMBERED = {
      "synchronous"               => {2_i64, "synchronous"},
      "cache_size"                => {Pager::DEFAULT_CACHE_SIZE, "cache_size"},
      "wal_autocheckpoint"        => {1000_i64, "wal_autocheckpoint"},
      "temp_store"                => {0_i64, "temp_store"},
      "recursive_triggers"        => {0_i64, "recursive_triggers"},
      "automatic_index"           => {1_i64, "automatic_index"},
      "legacy_alter_table"        => {0_i64, "legacy_alter_table"},
      "case_sensitive_like"       => {0_i64, "case_sensitive_like"},
      "secure_delete"             => {0_i64, "secure_delete"},
      "cell_size_check"           => {0_i64, "cell_size_check"},
      "mmap_size"                 => {0_i64, "mmap_size"},
      "query_only"                => {0_i64, "query_only"},
      "reverse_unordered_selects" => {0_i64, "reverse_unordered_selects"},
      "trusted_schema"            => {1_i64, "trusted_schema"},
      "max_page_count"            => {4294967294_i64, "max_page_count"},
      "threads"                   => {0_i64, "threads"},
      "writable_schema"           => {0_i64, "writable_schema"},
    }

    # PRAGMAs that answer with one row named after themselves.
    KNOWN_QUERIES = %w[foreign_keys defer_foreign_keys journal_mode user_version application_id schema_version
      page_size page_count freelist_count encoding]

    # PRAGMAs whose setting returns the new value as a row.
    SETTING_RETURNS_ROW = %w[busy_timeout wal_autocheckpoint mmap_size max_page_count threads]

    def initialize(@session : Session, @statement : SQL::Pragma)
      if schema = @statement.schema
        unless @session.schema?(schema.value)
          raise SQLError.new("unknown database #{schema.text}")
        end
      end
      name = @statement.name.value.downcase
      @list_of_column_names = case name
                              when "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list"
                                Catalog.function_columns("pragma_#{name}")
                              when "database_list"                  then %w[seq name file]
                              when "table_list"                     then Catalog.function_columns("pragma_table_list")
                              when "integrity_check", "quick_check" then [name]
                              when "busy_timeout"                   then %w[timeout]
                              when "cache_spill"                    then @statement.value ? [] of String : %w[cache_spill]
                              when "wal_checkpoint"                 then %w[busy log checkpointed]
                              when "foreign_key_check"              then ForeignKeyCheck.columns(@session, @statement.value.try { |text| PragmaPlan.unquote(text) })
                              else
                                if extra_columns = PragmaExtras.columns(name, @statement.value)
                                  extra_columns
                                elsif REMEMBERED.has_key?(name)
                                  @statement.value && !SETTING_RETURNS_ROW.includes?(name) ? [] of String : [REMEMBERED[name][1]]
                                elsif KNOWN_QUERIES.includes?(name) && (@statement.value.nil? || name == "journal_mode")
                                  [name]
                                else
                                  [] of String
                                end
                              end
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      name = @statement.name.value.downcase
      value = @statement.value.try { |text| PragmaPlan.unquote(text) }
      case name
      when "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list"
        return [] of Array(Value) unless value
        Catalog.rows("pragma_#{name}", value, @session)
      when "database_list"
        @session.database_list_rows
      when "table_list"
        Catalog.table_list(value, @session, @statement.schema.try(&.value))
      when "foreign_keys"
        return [[@session.foreign_keys? ? 1_i64 : 0_i64] of Value] unless value
        @session.foreign_keys = PragmaPlan.boolean(value) unless @session.in_transaction?
        [] of Array(Value)
      when "defer_foreign_keys"
        return [[@session.defer_foreign_keys? ? 1_i64 : 0_i64] of Value] unless value
        @session.defer_foreign_keys = PragmaPlan.boolean(value)
        [] of Array(Value)
      when "busy_timeout"
        if value
          @session.busy_timeout = Math.max(value.to_i? || 0, 0)
          @session.database.pager.busy_timeout = @session.busy_timeout.milliseconds
        end
        [[@session.busy_timeout.to_i64] of Value]
      when "cache_spill"
        cache_spill(value)
      when "journal_mode"
        journal_mode(value)
      when "wal_checkpoint"
        wal_checkpoint(value)
      when "user_version", "application_id"
        offset = name == "user_version" ? USER_VERSION_OFFSET : APPLICATION_ID_OFFSET
        if value
          number = (PragmaPlan.integer(value) || 0_i64).to_i32!
          @session.run_write(list_of_parameters, counts_changes: false) do
            @session.database.write_header_field(offset, number.to_u32!)
          end
          return [] of Array(Value)
        end
        [[header_field(offset).to_i32!.to_i64] of Value]
      when "schema_version"
        [[header_field(40).to_i64] of Value]
      when "page_size"
        # Setting it reports nothing (the engine keeps its page size).
        return [] of Array(Value) if value
        [[(@session.database.header.try(&.page_size) || Limits::DEFAULT_PAGE_SIZE).to_i64] of Value]
      when "page_count"
        [[@session.database.page_count.to_i64] of Value]
      when "freelist_count"
        [[header_field(36).to_i64] of Value]
      when "encoding"
        [["UTF-8"] of Value]
      when "integrity_check", "quick_check"
        IntegrityCheck.new(@session).rows
      when "foreign_key_check"
        ForeignKeyCheck.new(@session, value).rows
      else
        return PragmaExtras.rows(@session, name, value, @statement.schema.try(&.value)) if PragmaExtras.columns(name, value)
        if remembered = REMEMBERED[name]?
          if value
            number = PragmaPlan.integer(value) || PragmaPlan.named_level(name, value)
            @session.pragma_values[name] = number
            apply_to_pager(name, number)
            return SETTING_RETURNS_ROW.includes?(name) ? [[number] of Value] : [] of Array(Value)
          end
          return [[@session.pragma_values[name]? || remembered[0]] of Value]
        end
        [] of Array(Value)
      end
    end

    # PRAGMA cache_spill (pragma.c, PragTyp_CACHE_SPILL): read, the spill
    # size in pages, or 0 while spills are off. Set, a value that reads as
    # a 32-bit integer (sqlite3GetInt32) sets the size, and the value as a
    # boolean (sqlite3GetBoolean, defaulting to whether that integer, else
    # 1, is nonzero) turns spills on or off.
    private def cache_spill(value : String?) : Array(Array(Value))
      pager = @session.database.pager
      return [[pager.cache_spill_report] of Value] unless value
      size = PragmaPlan.c_int32(value)
      pager.cache_spill_size = size.to_i64 if size
      pager.cache_spill_allowed = PragmaPlan.c_boolean(value, (size || 1) != 0)
      [] of Array(Value)
    end

    JOURNAL_MODES = %w[delete persist off truncate memory wal]

    # journal_mode: WAL, or a rollback journal (the engine deletes it at
    # each commit whichever rollback mode is named, and reports the mode
    # named). Changing into or out of WAL is refused inside a transaction,
    # and leaving WAL needs every other connection closed. An in-memory
    # database reports "memory".
    private def journal_mode(value : String?) : Array(Array(Value))
      if @session.database.file_name.empty?
        return [["memory"] of Value]
      end
      pager = @session.database.pager
      current = pager.wal_mode? ? "wal" : (@session.pragma_values["journal_mode"]?.as?(String) || "delete")
      mode = value.try(&.downcase)
      return [[current] of Value] unless mode && JOURNAL_MODES.includes?(mode)
      if mode == "wal" || pager.wal_mode?
        if mode != current && @session.in_transaction?
          raise SQLError.new("cannot change #{mode == "wal" ? "into" : "out of"} wal mode from within a transaction")
        end
        begin
          mode == "wal" ? pager.enter_wal_mode : pager.leave_wal_mode
        rescue Busy
          raise SQLError.new("database is locked", 5)
        end
      end
      @session.pragma_values["journal_mode"] = mode
      [[mode] of Value]
    end

    # wal_checkpoint(MODE): busy, the WAL's frames and the frames copied;
    # 0, -1, -1 outside WAL mode. Refused inside a transaction.
    private def wal_checkpoint(value : String?) : Array(Array(Value))
      raise SQLError.new("database table is locked", 6) if @session.in_transaction?
      mode = case value.try(&.downcase)
             when "full"     then CheckpointMode::Full
             when "restart"  then CheckpointMode::Restart
             when "truncate" then CheckpointMode::Truncate
             else                 CheckpointMode::Passive
             end
      result = @session.database.pager.checkpoint(mode)
      [[result.busy ? 1_i64 : 0_i64, result.log_frames.to_i64, result.checkpointed_frames.to_i64] of Value]
    end

    # synchronous and wal_autocheckpoint act on the pager as well.
    private def apply_to_pager(name : String, number : Int64) : Nil
      pager = @session.database.pager
      case name
      when "synchronous"
        pager.synchronous = Synchronous.from_value(number.clamp(0_i64, 3_i64).to_i32)
      when "cache_size"
        pager.cache_size = number
      when "wal_autocheckpoint"
        pager.wal_autocheckpoint = number.clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i32
      end
    end

    private def header_field(offset : Int32) : UInt32
      return 0_u32 if @session.database.page_count == 0
      @session.database.pager.header_field(offset)
    end

    def self.unquote(text : String) : String
      return text if text.empty?
      first = text[0]
      if (first == '\'' || first == '"') && text.size >= 2 && text[-1] == first
        return text[1...-1].gsub("#{first}#{first}", first.to_s)
      end
      text
    end

    # sqlite3GetBoolean.
    def self.boolean(text : String) : Bool
      if number = integer(text)
        return number != 0
      end
      text.downcase.in?("on", "yes", "true", "full")
    end

    def self.integer(text : String) : Int64?
      text.strip.to_i64?
    end

    # sqlite3GetInt32: an optional sign and decimal digits (whatever
    # follows them is ignored), or unsigned hex with 0x, that fit in 31
    # bits and a sign; nil when the text does not start so.
    def self.c_int32(text : String) : Int32?
      bytes = text.to_slice
      position = 0
      negative = false
      first = bytes[0]?
      if first == '-'.ord
        negative = true
        position = 1
      elsif first == '+'.ord
        position = 1
      elsif first == '0'.ord && (bytes[1]? == 'x'.ord || bytes[1]? == 'X'.ord) && hex_digit(bytes[2]?)
        position = 2
        while bytes[position]? == '0'.ord
          position += 1
        end
        hex = 0_u32
        count = 0
        while count < 8 && (digit = hex_digit(bytes[position + count]?))
          hex = hex &* 16 &+ digit
          count += 1
        end
        return nil if (hex & 0x80000000_u32) != 0 || hex_digit(bytes[position + count]?)
        return hex.to_i32
      end
      byte = bytes[position]?
      return nil unless byte && byte.chr.ascii_number?
      while bytes[position]? == '0'.ord
        position += 1
      end
      number = 0_i64
      count = 0
      while count < 11 && (byte = bytes[position + count]?) && byte.chr.ascii_number?
        number = number * 10 + (byte - '0'.ord)
        count += 1
      end
      return nil if count > 10 || number - (negative ? 1 : 0) > Int32::MAX
      (negative ? -number : number).to_i32
    end

    private def self.hex_digit(byte : UInt8?) : UInt32?
      return unless byte
      byte.chr.to_u32?(16)
    end

    # sqlite3GetBoolean (getSafetyLevel with omitFull): text starting with
    # a digit is its sqlite3Atoi value cut to 8 bits, nonzero for true;
    # on, yes and true are true, no, off and false are false, ignoring
    # case; anything else is *default*.
    def self.c_boolean(text : String, default : Bool) : Bool
      first = text.to_slice[0]?
      return ((c_int32(text) || 0) & 0xff) != 0 if first && first.chr.ascii_number?
      case text.downcase
      when "on", "yes", "true"  then true
      when "no", "off", "false" then false
      else                           default
      end
    end

    # The keyword levels of synchronous and temp_store.
    def self.named_level(name : String, text : String) : Int64
      word = text.downcase
      case name
      when "synchronous"
        {"off" => 0_i64, "normal" => 1_i64, "full" => 2_i64, "extra" => 3_i64}[word]? || 1_i64
      when "temp_store"
        {"default" => 0_i64, "file" => 1_i64, "memory" => 2_i64}[word]? || 0_i64
      else
        boolean(text) ? 1_i64 : 0_i64
      end
    end
  end

  # PRAGMA integrity_check: every table and index b-tree is read, and each
  # row's entry in every index of its table is present, as are no others.
  class IntegrityCheck
    def initialize(@session : Session)
    end

    def rows : Array(Array(Value))
      problems = [] of String
      database = @session.database
      return [["ok"] of Value] if database.page_count == 0
      begin
        database.schema.list_of_tables.each do |entry|
          next unless entry.has_a_btree?
          table = @session.write_table(entry.object_name)
          next unless table
          counts = Hash(String, Int64).new(0_i64)
          run = WriteRun.new(@session, [] of Value)
          run.cursor_rows(table) do |rowid, row|
            table.list_of_index_layouts.each do |index|
              next unless run.index_includes?(table, index, row, rowid)
              counts[index.entry.object_name] += 1
              entry_values = run.index_entry(table, index, database.stored_values(table.definition, row), rowid)
              matched = database.index_entry_matching(index, entry_values)
              if matched.nil? && entry_values[0, index.key_count].none?(Nil)
                problems << "row #{rowid} missing from index #{index.entry.object_name}"
              end
            end
          end
          table.list_of_index_layouts.each do |index|
            entries = 0_i64
            database.each_index_entry(index.entry) { entries += 1 }
            if entries != counts[index.entry.object_name]
              problems << "wrong # of entries in index #{index.entry.object_name}"
            end
          end
        end
      rescue error : CorruptDatabase
        problems << (error.message || "database disk image is malformed")
      end
      return [["ok"] of Value] if problems.empty?
      problems.first(100).map { |problem| [problem] of Value }
    end
  end
end
