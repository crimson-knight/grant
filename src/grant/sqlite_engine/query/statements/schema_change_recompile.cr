module Grant::SQLiteEngine::Query
  # A prepared statement compiled before the schema changed (its tables
  # dropped and created again, so their root pages moved) compiles again
  # from its text when it next starts, as sqlite3_step re-prepares on
  # SQLITE_SCHEMA. The schema cookies of the main and temp databases tell.
  class PreparedQuery
    @sql = ""
    @compiled_schema_cookie : SchemaStamp? = nil

    def initialize(@session : Session, sql : String)
      previous_def
      @sql = sql
      @compiled_schema_cookie = @session.schema_stamp
    end

    def step : Bool
      recompile_after_schema_change if @frame.nil? && !@done
      previous_def
    end

    private def recompile_after_schema_change : Nil
      cookie = @session.schema_stamp
      return if cookie == @compiled_schema_cookie
      fresh = @session.prepare(@sql)
      @compiled = fresh.@compiled
      # The kept frame has the old plan's slots.
      @select_frame = nil
      @list_of_column_names = fresh.list_of_column_names
      @compiled_schema_cookie = fresh.@compiled_schema_cookie
    end
  end
end
