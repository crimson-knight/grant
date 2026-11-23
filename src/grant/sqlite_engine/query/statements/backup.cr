module Grant::SQLiteEngine::Query
  # The statements that make another database a copy of a session's main
  # schema (what sqlite3_backup leaves behind): the target's objects are
  # dropped, then every table is created and filled with its rows (rowids
  # kept), followed by sqlite_sequence, the indexes and the views.
  module Backup
    alias Step = {String, Array(Value)}

    def self.statements(source : Session, target : Session? = nil) : Array(Step)
      list = [] of Step
      database = source.database
      if target && target.database.page_count > 0
        target.database.schema.list_of_entries.each do |entry|
          next if entry.object_name.downcase.starts_with?("sqlite_")
          case entry.object_type
          when "table" then list << {"DROP TABLE IF EXISTS #{quote(entry.object_name)}", [] of Value}
          when "view"  then list << {"DROP VIEW IF EXISTS #{quote(entry.object_name)}", [] of Value}
          end
        end
      end
      return list if database.page_count == 0
      entries = database.schema.list_of_entries
      sequence = nil.as(SchemaEntry?)
      entries.each do |entry|
        next unless entry.table?
        if entry.object_name == Database::SEQUENCE_TABLE
          sequence = entry
          next
        end
        sql = entry.sql
        next unless sql && entry.has_a_btree?
        list << {sql, [] of Value}
        info = source.table(entry.object_name) || next
        columns = info.list_of_column_names.map { |column| quote(column) }
        rowid = !info.without_rowid? && info.rowid_alias.nil?
        names = (rowid ? ["rowid"] : [] of String) + columns
        insert = "INSERT INTO #{quote(entry.object_name)}(#{names.join(", ")}) VALUES (#{names.map { "?" }.join(", ")})"
        run = WriteRun.new(source, [] of Value)
        table = source.write_table(entry.object_name) || next
        run.cursor_rows(table) do |row_rowid, row|
          values = rowid ? [row_rowid.as(Value)] + row : row
          list << {insert, values}
        end
      end
      if sequence_entry = sequence
        list << {"DELETE FROM sqlite_sequence", [] of Value}
        database.each_table_btree_record(sequence_entry.root_page) do |_rowid, values|
          list << {"INSERT INTO sqlite_sequence(name, seq) VALUES (?, ?)", [values[0]?, values[1]?] of Value}
        end
      end
      entries.each do |entry|
        sql = entry.sql
        next unless sql
        list << {sql, [] of Value} if entry.index? || entry.object_type == "view"
      end
      list
    end

    private def self.quote(name : String) : String
      %("#{name.gsub('"', "\"\"")}")
    end
  end
end
