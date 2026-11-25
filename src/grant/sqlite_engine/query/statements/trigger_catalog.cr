module Grant::SQLiteEngine::Query
  # One trigger of a schema (lang_createtrigger.html): its CREATE TRIGGER,
  # parsed from the sqlite_schema row, and the database that holds it.
  class TriggerDefinition
    getter trigger_name : String
    # The table or view the trigger fires on, as the CREATE TRIGGER wrote
    # it (sqlite_schema's tbl_name).
    getter table_name : String
    getter statement : SQL::CreateTrigger
    getter database : Database

    def initialize(@trigger_name : String, @table_name : String, @statement : SQL::CreateTrigger, @database : Database)
    end

    def event : SQL::TriggerEvent
      @statement.event
    end

    # sqlite3BeginTrigger codes INSTEAD OF as a BEFORE trigger of a view,
    # and a trigger with no time as BEFORE.
    def before? : Bool
      !@statement.time.after?
    end

    def instead_of? : Bool
      @statement.time.instead_of?
    end

    # checkColumnOverlap: an UPDATE OF trigger fires when the statement
    # assigns one of its columns, matched by the names the SET list wrote.
    # *list_of_changed_names* is nil for INSERT and DELETE.
    def fires_for?(list_of_changed_names : Array(String)?) : Bool
      columns = @statement.update_columns
      return true if columns.nil? || list_of_changed_names.nil?
      columns.any? { |column| list_of_changed_names.any? { |changed| column.same?(changed) } }
    end
  end

  class Session
    # Every trigger of every database, temp first, each database's in
    # schema order; read again after a schema change.
    @list_of_triggers : Array(TriggerDefinition)? = nil

    def reset_schema : Nil
      previous_def
      @list_of_triggers = nil
    end

    # PRAGMA recursive_triggers (off by default, as in C).
    def recursive_triggers? : Bool
      @pragma_values["recursive_triggers"]? == 1_i64
    end

    def list_of_triggers : Array(TriggerDefinition)
      check_schema
      @list_of_triggers ||= read_triggers
    end

    # The trigger named *name* in *database* (case-insensitive), or nil.
    def trigger_named(name : String, database : Database) : TriggerDefinition?
      list_of_triggers.find { |trigger| trigger.database.same?(database) && trigger.trigger_name.compare(name, case_insensitive: true) == 0 }
    end

    # sqlite3TriggerList: the triggers of the table or view *name* of
    # *database* in the order C fires them. TEMP triggers on a table of
    # another database come first, oldest first; then the database's own,
    # newest first (each new trigger goes to the head of its table's list).
    def list_of_triggers_on(name : String, database : Database) : Array(TriggerDefinition)
      all = list_of_triggers
      return NO_TRIGGERS if all.empty?
      list = [] of TriggerDefinition
      temp_database = @temp_database
      if temp_database && !database.same?(temp_database)
        all.each do |trigger|
          next unless trigger.database.same?(temp_database) && trigger.table_name.compare(name, case_insensitive: true) == 0
          list << trigger if table_database_of(trigger).same?(database)
        end
      end
      all.reverse_each do |trigger|
        next unless trigger.database.same?(database) && trigger.table_name.compare(name, case_insensitive: true) == 0
        next if database.same?(temp_database) && !table_database_of(trigger).same?(database)
        list << trigger
      end
      list
    end

    # The list of a table no trigger names; nothing changes it.
    NO_TRIGGERS = [] of TriggerDefinition

    # The database of the table a trigger fires on (pTabSchema): its own,
    # except that a TEMP trigger may name a table of any database, by a
    # qualified name or by the search order (temp, main, attached).
    def table_database_of(trigger : TriggerDefinition) : Database?
      return trigger.database unless trigger.database.same?(@temp_database)
      name = trigger.table_name
      if schema = trigger.statement.table_schema
        return existing_database_named(schema.value)
      end
      return table(name).try(&.database) if table(name)
      view(name) ? @database : nil
    end

    private def read_triggers : Array(TriggerDefinition)
      list = [] of TriggerDefinition
      each_database_in_search_order do |database|
        next if database.page_count == 0
        database.schema.list_of_entries.each do |entry|
          next unless entry.object_type == "trigger"
          sql = entry.sql
          next unless sql
          statement = begin
            SQL::Parser.parse_schema(sql)
          rescue error : SQL::ParseError
            raise CorruptDatabase.new("malformed database schema (#{entry.object_name}) - #{error.message}")
          end
          next unless statement.is_a?(SQL::CreateTrigger)
          list << TriggerDefinition.new(entry.object_name, entry.table_name, statement, database)
        end
      end
      list
    end
  end
end
