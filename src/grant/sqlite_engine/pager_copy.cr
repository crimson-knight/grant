module Grant::SQLiteEngine
  class Pager
    # Makes this database a page-for-page copy of *source*, as
    # sqlite3_backup_step run to completion does: every page of the source's
    # snapshot (WAL frames and the pages its open transaction changed
    # included) replaces the page of the same number here, the header fields
    # travel with page 1, and pages past the source's last are dropped. An
    # empty source leaves a new, empty database (sqlite3BtreeNewDb).
    #
    # The copy is one transaction on this database. Raises `Busy` when
    # another connection holds a lock it needs or *source* has a write
    # transaction open (sqlite3_backup_step's rule), and `ReadOnlyDatabase` for a
    # WAL-mode database whose page size differs from the source's, as C does.
    def replace_contents_with(source : Pager) : Nil
      raise Error.new("source and destination must be distinct") if same?(source)
      raise Error.new("destination database is in use") if @in_write_transaction
      raise Busy.new if source.in_write_transaction?
      source.with_read_lock do
        if source.page_count == 0
          own_page_size = @page_size > 0 ? @page_size : @new_page_size
          blank = Pager.open_read_write(MemoryFileSystem.new, ":memory:", page_size: own_page_size)
          blank.begin_write
          blank.commit
          copy_pages_of(blank)
        else
          copy_pages_of(source)
        end
      end
    end

    private def copy_pages_of(source : Pager) : Nil
      if @page_count > 0 && @page_size != source.page_size
        raise ReadOnlyDatabase.new if wal_mode?
        rewrite_with_pages_of(source)
      else
        write_pages_of(source)
      end
      follow_copied_journal_mode
    end

    # The copy between databases of one page size (or into an empty one,
    # which takes the source's): an ordinary write transaction that changes
    # every page, so the rollback journal or the WAL makes it atomic.
    private def write_pages_of(source : Pager) : Nil
      page_size_for_new_database = @new_page_size
      @new_page_size = source.page_size if @page_count == 0
      begin_write
      begin
        last_page = source.page_count
        skipped_page = lock_byte_page
        (1_u32..last_page).each do |page_number|
          next if page_number == skipped_page
          page_for_write(page_number).copy_from(source.read_page(page_number))
        end
        @page_count = last_page
        mark_file_format(page_for_write(1_u32))
        commit
      rescue error
        rollback
        @new_page_size = page_size_for_new_database
        raise error
      end
      @new_page_size = page_size_for_new_database
      @cache.reject! { |page_number, _| page_number > @page_count }
      @rightmost_path_hint = nil
      @generation += 1
      drop_pages_past_the_end
    end

    # sqlite3_backup_step ends with sqlite3BtreeSetVersion(pDest, 2) for a
    # WAL-mode destination: the copy of a rollback-journal database stays in
    # WAL mode.
    private def mark_file_format(page_one : Bytes) : Nil
      return unless wal_mode?
      page_one[18] = 2_u8
      page_one[19] = 2_u8
    end

    # A rollback-journal database that received the pages of a WAL-mode one
    # now has a header that says WAL; it uses the WAL from here on, as C
    # does at its next transaction (lockBtree).
    private def follow_copied_journal_mode : Nil
      return if wal_mode? || !wal_wanted?
      raise Busy.new unless writer_file.lock(LockLevel::Shared)
      open_log
      load_log_snapshot
    end

    # Shortens the file to the copied size once the copy is committed. The
    # header's page count is already right, so a file left long (another
    # connection is using it) is still a correct database.
    private def drop_pages_past_the_end : Nil
      return if wal_mode?
      file = writer_file
      wanted_size = @page_count.to_i64 * @page_size
      return if file.size <= wanted_size
      return unless file.lock(LockLevel::Shared)
      begin
        if file.lock(LockLevel::Reserved) && file.lock(LockLevel::Exclusive) && !changed_on_disk?(file)
          file.truncate(wanted_size)
          file.sync
        end
      ensure
        file.unlock(@read_depth > 0 ? LockLevel::Shared : LockLevel::None)
      end
    end

    # The copy into a rollback-journal database of another page size: under
    # the EXCLUSIVE lock, a journal of every original page is written and
    # synced, then the file is rewritten at the source's page size and the
    # journal deleted, which is the moment the copy commits. A crash before
    # that leaves a hot journal that restores the original database.
    private def rewrite_with_pages_of(source : Pager) : Nil
      file = writer_file
      file_system = writer_file_system
      begin_write
      journal_path = RollbackJournal.path_for(@path)
      journal_written = false
      begin
        raise Busy.new unless file.lock(LockLevel::Exclusive)
        skipped_page = lock_byte_page
        list_of_images = [] of {UInt32, Bytes}
        (1_u32..@page_count).each do |page_number|
          list_of_images << {page_number, read_page(page_number).dup} unless page_number == skipped_page
        end
        journal = file_system.open(journal_path)
        begin
          RollbackJournal.write(journal, @page_size, @original_page_count, list_of_images, Random.rand(UInt32))
        ensure
          journal.close
        end
        journal_written = true
        new_page_size = source.page_size
        last_page = source.page_count
        skipped_page = source.lock_byte_page
        (1_u32..last_page).each do |page_number|
          next if page_number == skipped_page
          page = source.read_page(page_number)
          if page_number == 1_u32
            page = page.dup
            counter = get_u32(page, CHANGE_COUNTER_OFFSET) &+ 1
            put_u32(page, CHANGE_COUNTER_OFFSET, counter)
            put_u32(page, PAGE_COUNT_OFFSET, last_page)
            put_u32(page, VERSION_VALID_FOR_OFFSET, counter)
            put_u32(page, VERSION_NUMBER_OFFSET, WRITER_VERSION_NUMBER)
          end
          file.write_at((page_number.to_i64 - 1) * new_page_size, page)
        end
        file.truncate(last_page.to_i64 * new_page_size)
        file.sync
        file_system.delete(journal_path)
        journal_written = false
      ensure
        if journal_written
          journal = file_system.open(journal_path)
          begin
            RollbackJournal.play_back(journal, file)
          ensure
            journal.close
          end
          file_system.delete(journal_path)
        end
        @dirty.clear
        @rightmost_path_hint = nil
        reload
        finish_transaction(file)
      end
    end
  end
end
