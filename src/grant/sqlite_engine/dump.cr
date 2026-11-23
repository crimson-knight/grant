require "json"

module Grant::SQLiteEngine
  # Writes every table and index of a database as JSON lines in a canonical,
  # typed form, so two engines' views of one file compare line by line:
  #
  # ```text
  # # table users
  # [1,"ada@example.com",{"real":"0x3FF8000000000000"},{"blob":"00FF"},null]
  # # index users_by_email
  # ["ada@example.com",1]
  # ```
  #
  # A table row starts with its rowid (null for WITHOUT ROWID tables).
  # INTEGER values are JSON numbers, TEXT values JSON strings, NULL is null,
  # REAL values `{"real": "0x<IEEE 754 bits in upper-case hex>"}` (exact, so
  # -0.0 and the last bit of every double compare) and BLOB values
  # `{"blob": "<upper-case hex>"}`. Objects are written in name order.
  class Dump
    def initialize(@database : Database, @include_indexes : Bool = true)
    end

    # Writes the dump from one snapshot of the database.
    def write(io : IO) : Nil
      @database.pager.with_read_lock { write_snapshot(io) }
    end

    private def write_snapshot(io : IO) : Nil
      schema = @database.schema
      objects = schema.list_of_tables + (@include_indexes ? schema.list_of_indexes : [] of SchemaEntry)
      objects.sort_by!(&.object_name.to_slice).each do |entry|
        if entry.table?
          io << "# table " << entry.object_name << '\n'
          @database.each_row(entry) { |row| write_line(io, row.rowid, row.values) }
        else
          io << "# index " << entry.object_name << '\n'
          @database.each_index_entry(entry) { |record| write_line(io, nil, record, leading_rowid: false) }
        end
      end
    end

    private def write_line(io : IO, rowid : Int64?, values : Array(Value), leading_rowid : Bool = true) : Nil
      JSON.build(io) do |json|
        json.array do
          json.scalar(rowid) if leading_rowid
          values.each { |value| Dump.write_value(json, value) }
        end
      end
      io << '\n'
    end

    def self.write_value(json : JSON::Builder, value : Value) : Nil
      case value
      when Float64
        json.object { json.field("real", "0x%016X" % value.unsafe_as(UInt64)) }
      when Bytes
        json.object { json.field("blob", value.hexstring.upcase) }
      else
        json.scalar(value)
      end
    end
  end
end
