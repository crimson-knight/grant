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
      list_of_secondary_databases.each(&.forget_layouts)
    end

    # The rules for writing rows of *name*, or nil when there is no such
    # table.
    def write_table(name : String, schema : String? = nil) : WriteTable?
      info = table(name, schema)
      return unless info
      key = "#{schema.try(&.downcase)}\0#{name.downcase}"
      cached = @write_tables[key]?
      return cached if cached && cached.table_info.same?(info)
      info.check_readable
      @write_tables[key] = WriteTable.new(info, info.database.write_layout(info.name))
    end

    # The tables whose foreign keys name *parent* (lower case names).
    def list_of_child_tables(parent : String) : Array(String)
      map = @child_tables ||= begin
        found = {} of String => Array(String)
        list_of_databases.each do |database|
          next if database.page_count == 0
          database.schema.list_of_tables.each do |entry|
            next unless entry.has_a_btree?
            sql = entry.sql
            next unless sql && sql.matches?(/references/i)
            rules = write_table(entry.object_name, schema_name_of(database))
            next unless rules
            rules.list_of_foreign_keys.each do |rule|
              list = found[rule.parent_table.downcase] ||= [] of String
              list << entry.object_name unless list.includes?(entry.object_name)
            end
          end
        end
        found
      end
      map[parent.downcase]? || [] of String
    end

    # --- Transactions -------------------------------------------------------
    #
    # The pagers of temp and of each attached database follow the main
    # pager's transaction: each joins a write transaction when one is open,
    # keeps a savepoint for every main savepoint opened while it takes part
    # (its marks map main depth to its own depth), and commits or rolls
    # back with main. A rollback to a savepoint opened before a database
    # joined undoes all of that database's part.

    @secondary_marks = {} of Database => Hash(Int32, Int32)

    private def join_secondary_writes : Nil
      list_of_secondary_databases.each { |database| join_one_write(database) }
    end

    private def join_one_write(database : Database) : Nil
      database.pager.begin_write unless database.pager.in_write_transaction?
    end

    private def forget_secondary_marks(database : Database) : Nil
      @secondary_marks.delete(database)
    end

    private def each_secondary_in_write(& : Database ->) : Nil
      list_of_secondary_databases.each do |database|
        yield database if database.pager.in_write_transaction?
      end
    end

    private def open_savepoint_everywhere : Int32
      depth = @database.pager.open_savepoint
      each_secondary_in_write do |database|
        (@secondary_marks[database] ||= {} of Int32 => Int32)[depth] = database.pager.open_savepoint
      end
      depth
    end

    private def release_savepoint_everywhere(depth : Int32) : Nil
      @database.pager.release_savepoint(depth)
      each_secondary_in_write do |database|
        marks = @secondary_marks[database]?
        next unless marks
        if own_depth = marks[depth]?
          database.pager.release_savepoint(own_depth)
        end
        marks.reject! { |main_depth, _| main_depth >= depth }
      end
    end

    private def rollback_to_savepoint_everywhere(depth : Int32) : Nil
      @database.pager.rollback_to_savepoint(depth)
      each_secondary_in_write do |database|
        marks = @secondary_marks[database]?
        if marks && (own_depth = marks[depth]?)
          database.pager.rollback_to_savepoint(own_depth)
          marks.reject! { |main_depth, _| main_depth > depth }
        else
          database.pager.rollback
          @secondary_marks.delete(database)
          database.pager.begin_write
        end
      end
    end

    private def commit_secondaries : Nil
      each_secondary_in_write(&.pager.commit)
      @secondary_marks.clear
    end

    private def commit_everywhere : Nil
      @database.pager.commit
      commit_secondaries
    end

    private def rollback_everywhere : Nil
      @database.pager.rollback
      each_secondary_in_write(&.pager.rollback)
      @secondary_marks.clear
    end

    # Takes the write lock for the open transaction or for one statement,
    # waiting up to busy_timeout for another connection to finish. The
    # SAVEPOINTs of a deferred transaction declared before its first write
    # open in the pager here.
    #
    # In WAL mode a transaction that already read keeps its snapshot, so a
    # busy WRITE lock or a newer commit fails at once ("database is
    # locked"), as C skips the busy handler once a read transaction is
    # open. A statement that starts a write moves to the newest snapshot;
    # when that changed the schema, the statement fails with
    # SQLITE_SCHEMA rather than run a plan compiled for the old one.
    def begin_write_transaction : Nil
      pager = @database.pager
      if pager.in_write_transaction?
        join_secondary_writes
        return
      end
      if pager.wal_mode? && @transaction_snapshot_pinned
        begin
          pager.begin_write(refresh_snapshot: false)
        rescue Busy
          raise SQLError.new("database is locked", 5)
        end
      else
        generation = pager.generation
        cookie = @database.header.try(&.schema_cookie)
        wait_while_busy { pager.begin_write }
        if pager.wal_mode? && pager.generation != generation && @database.header.try(&.schema_cookie) != cookie
          pager.rollback
          reset_schema
          raise SQLError.new("database schema has changed", 17)
        end
      end
      join_secondary_writes
      refresh_after_other_connections
      @list_of_savepoints.each_with_index do |mark, position|
        next unless mark.depth < 0
        @list_of_savepoints[position] = mark.copy_with(depth: open_savepoint_everywhere)
      end
    end

    # Runs *block* until it stops raising Busy, for up to busy_timeout
    # milliseconds (sqlite3_busy_timeout), then raises "database is locked".
    private def wait_while_busy(& : ->) : Nil
      deadline = Time.instant + @busy_timeout.milliseconds
      loop do
        yield
        return
      rescue Busy
        raise SQLError.new("database is locked", 5) if Time.instant >= deadline
        sleep 1.millisecond
      end
    end

    @seen_generation = 0
    @holds_transaction_read_lock = false

    # A statement starts reading: a SHARED lock for the statement, and in a
    # transaction one more held until it ends, as C keeps SHARED from the
    # first read to COMMIT. Pages and schema another connection changed are
    # dropped first.
    def begin_statement_read : Nil
      pager = @database.pager
      wait_while_busy { pager.acquire_read_lock }
      if @in_transaction && !@holds_transaction_read_lock
        pager.acquire_read_lock
        @holds_transaction_read_lock = true
      end
      refresh_after_other_connections
    end

    def end_statement_read : Nil
      @database.pager.release_read_lock
      @transaction_snapshot_pinned = true if @holds_transaction_read_lock
    end

    # A statement of the open transaction finished under its read lock, so
    # the transaction has read from its snapshot.
    @transaction_snapshot_pinned = false

    # The schema cache goes when the pager reloaded what another
    # connection committed.
    private def refresh_after_other_connections : Nil
      generation = @database.pager.generation
      return if generation == @seen_generation
      @seen_generation = generation
      reset_schema
    end

    # BEGIN: opens a transaction. IMMEDIATE and EXCLUSIVE take the write
    # lock at once; DEFERRED takes it at the first write, so connections
    # that only read never wait for one another.
    def begin_transaction(immediate : Bool = false) : Nil
      raise SQLError.new("cannot start a transaction within a transaction") if @in_transaction
      begin_write_transaction if immediate
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
      commit_everywhere if @database.pager.in_write_transaction?
      end_transaction
    end

    # ROLLBACK of the whole transaction. The schema caches go only when the
    # rollback put back a schema change in some database (its pager's
    # generation moves then), as C resets the schema only after
    # DBFLAG_SchemaChange.
    def rollback_transaction : Nil
      raise SQLError.new("cannot rollback - no transaction is active") unless @in_transaction
      list_of_pagers = [@database.pager] + list_of_secondary_databases.map(&.pager)
      list_of_generations = list_of_pagers.map(&.generation)
      rollback_everywhere
      end_transaction
      reset_schema unless list_of_pagers.map(&.generation) == list_of_generations
    end

    private def end_transaction : Nil
      @in_transaction = false
      @transaction_snapshot_pinned = false
      @opened_by_savepoint = false
      @list_of_savepoints.clear
      @deferred_violations = 0_i64
      if @holds_transaction_read_lock
        @holds_transaction_read_lock = false
        @database.pager.release_read_lock
      end
    end

    # SAVEPOINT: a pager savepoint once the transaction writes (depth -1
    # until then, since nothing before the first write needs undoing).
    def savepoint(name : String) : Nil
      unless @in_transaction
        begin_transaction
        @opened_by_savepoint = true
      end
      depth = @database.pager.in_write_transaction? ? open_savepoint_everywhere : -1
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
      release_savepoint_everywhere(mark.depth) if mark.depth >= 0
      @list_of_savepoints.delete_at(position..)
    end

    # ROLLBACK TO: undoes everything since the savepoint, which stays open.
    def rollback_to(name : String) : Nil
      position = savepoint_position(name)
      mark = @list_of_savepoints[position]
      rollback_to_savepoint_everywhere(mark.depth) if mark.depth >= 0
      @list_of_savepoints.delete_at((position + 1)..)
      @deferred_violations = mark.deferred_violations
      reset_schema
    end

    # Runs one write statement: in the open transaction under a statement
    # journal, or in a transaction of its own. A failure undoes the
    # statement (ABORT), keeps its earlier changes (FAIL) or ends the
    # transaction (ROLLBACK); changes() and total_changes() count the rows
    # of a statement that finished.
    #
    # With *returning*, an autocommit statement that returned rows keeps
    # its transaction open until those rows are read (or the statement is
    # reset), as C commits at OP_Halt: `finish_pending_commit`.
    def run_write(list_of_parameters : Array(Value), counts_changes : Bool = true, returning : Bool = false, & : WriteRun -> T) : T forall T
      finish_pending_commit
      autocommit = !@in_transaction
      begin_write_transaction
      pager = @database.pager
      depth = open_savepoint_everywhere
      saved_deferred = @deferred_violations
      run = WriteRun.new(self, list_of_parameters)
      hold = false
      begin
        result = yield run
        run.finish_autoincrement
        # RETURNING hands out one row per changed row.
        hold = autocommit && returning && run.changes > 0
        if run.immediate_violations > 0 || (autocommit && !hold && @deferred_violations > 0)
          raise ConstraintError.new("FOREIGN KEY constraint failed")
        end
      rescue error : ConstraintError
        # sqlite3VdbeCheckFk at OP_Halt: a FAIL that leaves immediate
        # foreign key violations becomes an ABORT of them.
        if error.action.fail? && run.immediate_violations > 0
          error = ConstraintError.new("FOREIGN KEY constraint failed")
        end
        if error.action.fail?
          release_savepoint_everywhere(depth)
          commit_statement_transaction if autocommit
          record_changes(run.changes) if counts_changes
        elsif error.action.rollback?
          rollback_everywhere
          end_transaction
          reset_schema
          record_changes(0_i64) if counts_changes
        else
          undo_statement(depth, autocommit, saved_deferred)
          record_changes(0_i64) if counts_changes
        end
        raise error
      rescue error
        if !autocommit && !run.statement_journal? && error.is_a?(SQLError) && pager.in_write_transaction?
          release_savepoint_everywhere(depth)
        else
          undo_statement(depth, autocommit, saved_deferred)
        end
        record_changes(0_i64) if counts_changes
        raise error
      end
      release_savepoint_everywhere(depth)
      record_changes(run.changes) if counts_changes
      if autocommit
        if hold
          @pending_commit = true
        else
          commit_statement_transaction
        end
      end
      result
    end

    # An autocommit statement's RETURNING rows are still being read.
    getter? pending_commit = false

    # Commits the transaction of an autocommit statement that returned
    # rows: deferred foreign keys must hold, and a reader of another
    # connection can refuse the commit ("database is locked"). A failed
    # commit undoes the statement.
    def finish_pending_commit : Nil
      return unless @pending_commit
      @pending_commit = false
      if @deferred_violations > 0
        rollback_everywhere
        @deferred_violations = 0_i64
        reset_schema
        raise ConstraintError.new("FOREIGN KEY constraint failed")
      end
      commit_statement_transaction
    end

    # Commits one autocommit statement's transaction, waiting up to
    # busy_timeout for readers; a commit still refused rolls back.
    private def commit_statement_transaction : Nil
      @deferred_violations = 0_i64
      begin
        wait_while_busy { @database.pager.commit }
        commit_secondaries
      rescue error
        rollback_everywhere
        reset_schema
        raise error
      end
    end

    private def undo_statement(depth : Int32, autocommit : Bool, saved_deferred : Int64) : Nil
      pager = @database.pager
      if autocommit
        rollback_everywhere
        @deferred_violations = 0_i64
      elsif pager.in_write_transaction?
        rollback_to_savepoint_everywhere(depth)
        release_savepoint_everywhere(depth)
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
