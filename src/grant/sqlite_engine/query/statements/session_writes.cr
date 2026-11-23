module Grant::SQLiteEngine::Query
  # A SAVEPOINT on the session's stack: its name, the pager's savepoint
  # depth for it, and the deferred foreign key count when it opened.
  record SavepointMark, savepoint_name : String, depth : Int32, deferred_violations : Int64

  class Session
    # PRAGMA foreign_keys (off by default, as C's default build).
    property? foreign_keys = false
    # PRAGMA defer_foreign_keys: immediate constraints count as deferred.
    property? defer_foreign_keys = false
    # Deferred FOREIGN KEY violations of the open transaction
    # (db->nDeferredCons), checked at COMMIT.
    property deferred_violations = 0_i64
    # PRAGMA busy_timeout, in milliseconds.
    property busy_timeout = 0
    # The values the PRAGMAs the engine accepts without acting on report.
    getter pragma_values = {} of String => Value

    # True between BEGIN (or a SAVEPOINT outside a transaction) and the
    # COMMIT or ROLLBACK that ends it.
    getter? in_transaction = false
    getter list_of_savepoints = [] of SavepointMark
    # The transaction was opened by SAVEPOINT, so releasing its outermost
    # savepoint commits it.
    @opened_by_savepoint = false

    @write_tables = {} of String => WriteTable?
    @child_tables : Hash(String, Array(String))? = nil

    def reset_schema : Nil
      previous_def
      @write_tables.clear
      @child_tables = nil
      @database.forget_layouts
    end

    # The rules for writing rows of *name*, or nil when there is no such
    # table.
    def write_table(name : String) : WriteTable?
      info = table(name)
      return unless info
      key = name.downcase
      cached = @write_tables[key]?
      return cached if cached && cached.table_info.same?(info)
      info.check_readable
      @write_tables[key] = WriteTable.new(info, @database.write_layout(info.name))
    end

    # The tables whose foreign keys name *parent* (lower case names).
    def list_of_child_tables(parent : String) : Array(String)
      map = @child_tables ||= begin
        found = {} of String => Array(String)
        @database.schema.list_of_tables.each do |entry|
          next unless entry.has_a_btree?
          sql = entry.sql
          next unless sql && sql.matches?(/references/i)
          rules = write_table(entry.object_name)
          next unless rules
          rules.list_of_foreign_keys.each do |rule|
            list = found[rule.parent_table.downcase] ||= [] of String
            list << entry.object_name unless list.includes?(entry.object_name)
          end
        end
        found
      end
      map[parent.downcase]? || [] of String
    end

    # --- Transactions -------------------------------------------------------

    # Takes the write lock for the open transaction or for one statement,
    # waiting up to busy_timeout for another connection to finish.
    def begin_write_transaction : Nil
      pager = @database.pager
      return if pager.in_write_transaction?
      deadline = Time.instant + @busy_timeout.milliseconds
      loop do
        begin
          pager.begin_write
          return
        rescue Busy
          raise SQLError.new("database is locked", 5) if Time.instant >= deadline
          sleep 1.millisecond
        end
      end
    end

    # BEGIN: opens a transaction. The write lock is taken at once (the
    # engine has one writer per file; DEFERRED differs from IMMEDIATE only
    # in when SQLITE_BUSY can arrive).
    def begin_transaction : Nil
      raise SQLError.new("cannot start a transaction within a transaction") if @in_transaction
      begin_write_transaction
      @in_transaction = true
      @opened_by_savepoint = false
      @deferred_violations = 0_i64
    end

    # COMMIT / END: deferred foreign keys must hold.
    def commit_transaction : Nil
      raise SQLError.new("cannot commit - no transaction is active") unless @in_transaction
      if @deferred_violations > 0
        raise ConstraintError.new("FOREIGN KEY constraint failed")
      end
      pager = @database.pager
      pager.commit if pager.in_write_transaction?
      end_transaction
    end

    # ROLLBACK of the whole transaction.
    def rollback_transaction : Nil
      raise SQLError.new("cannot rollback - no transaction is active") unless @in_transaction
      @database.pager.rollback
      end_transaction
      reset_schema
    end

    private def end_transaction : Nil
      @in_transaction = false
      @opened_by_savepoint = false
      @list_of_savepoints.clear
      @deferred_violations = 0_i64
    end

    def savepoint(name : String) : Nil
      unless @in_transaction
        begin_transaction
        @opened_by_savepoint = true
      end
      begin_write_transaction
      depth = @database.pager.open_savepoint
      @list_of_savepoints << SavepointMark.new(name, depth, @deferred_violations)
    end

    private def savepoint_position(name : String) : Int32
      position = @list_of_savepoints.rindex { |mark| mark.savepoint_name.compare(name, case_insensitive: true) == 0 }
      raise SQLError.new("no such savepoint: #{name}") unless position
      position
    end

    # RELEASE: closes the savepoint and those inside it; releasing the
    # outermost savepoint of a transaction SAVEPOINT opened commits it.
    def release(name : String) : Nil
      position = savepoint_position(name)
      if position == 0 && @opened_by_savepoint
        commit_transaction
        return
      end
      mark = @list_of_savepoints[position]
      @database.pager.release_savepoint(mark.depth)
      @list_of_savepoints.delete_at(position..)
    end

    # ROLLBACK TO: undoes everything since the savepoint, which stays open.
    def rollback_to(name : String) : Nil
      position = savepoint_position(name)
      mark = @list_of_savepoints[position]
      @database.pager.rollback_to_savepoint(mark.depth)
      @list_of_savepoints.delete_at((position + 1)..)
      @deferred_violations = mark.deferred_violations
      reset_schema
    end

    # Runs one write statement: in the open transaction under a statement
    # journal, or in a transaction of its own. A failure undoes the
    # statement (ABORT), keeps its earlier changes (FAIL) or ends the
    # transaction (ROLLBACK); changes() and total_changes() count the rows
    # of a statement that finished.
    def run_write(list_of_parameters : Array(Value), counts_changes : Bool = true, & : WriteRun -> T) : T forall T
      autocommit = !@in_transaction
      begin_write_transaction
      pager = @database.pager
      depth = pager.open_savepoint
      saved_deferred = @deferred_violations
      run = WriteRun.new(self, list_of_parameters)
      begin
        result = yield run
        run.finish_autoincrement
        if run.immediate_violations > 0 || (autocommit && @deferred_violations > 0)
          raise ConstraintError.new("FOREIGN KEY constraint failed")
        end
      rescue error : ConstraintError
        if error.action.fail?
          pager.release_savepoint(depth)
          pager.commit if autocommit
          @deferred_violations = 0_i64 if autocommit
          record_changes(run.changes) if counts_changes
        elsif error.action.rollback?
          pager.rollback
          end_transaction
          reset_schema
          record_changes(0_i64) if counts_changes
        else
          undo_statement(depth, autocommit, saved_deferred)
          record_changes(0_i64) if counts_changes
        end
        raise error
      rescue error
        undo_statement(depth, autocommit, saved_deferred)
        record_changes(0_i64) if counts_changes
        raise error
      end
      pager.release_savepoint(depth)
      if autocommit
        pager.commit
        @deferred_violations = 0_i64
      end
      record_changes(run.changes) if counts_changes
      result
    end

    private def undo_statement(depth : Int32, autocommit : Bool, saved_deferred : Int64) : Nil
      pager = @database.pager
      if autocommit
        pager.rollback
        @deferred_violations = 0_i64
      elsif pager.in_write_transaction?
        pager.rollback_to_savepoint(depth)
        pager.release_savepoint(depth)
        @deferred_violations = saved_deferred
      end
      reset_schema
    end

    private def record_changes(count : Int64) : Nil
      @changes = count
      @total_changes += count
    end
  end
end
