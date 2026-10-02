require "./alter_table"
require "./model_indexes"

module Grant::Schema
  module AlterStatements
    # Returns the SQL that builds a GIN index over *columns*, the index the
    # array containment and JSON predicates (`@>`, `&&`, `?`) need to avoid a
    # sequential scan. It is `add_index_statements` with `using: :gin`, and takes
    # its other options (`name`, `opclass`, `where`, `algorithm`, `if_not_exists`).
    # GIN is PostgreSQL only.
    #
    # ```
    # add_gin_index_statements(:posts, :tags)
    # # => CREATE INDEX "index_posts_on_tags" ON "posts" USING gin ("tags")
    # ```
    def add_gin_index_statements(table : TableName, columns : ColumnNames, name : ::String | Symbol | Nil = nil,
                                 where : ::String? = nil, opclass = nil, algorithm : Symbol? = nil,
                                 if_not_exists : Bool = false, comment : ::String? = nil) : Array(::String)
      raise UnsupportedOperation.new("GIN indexes are only supported on PostgreSQL") unless dialect.pg?
      add_index_statements(table, columns, name: name, where: where, using: :gin, opclass: opclass,
        algorithm: algorithm, if_not_exists: if_not_exists, comment: comment)
    end

    # Runs the statements of `#add_gin_index_statements`.
    def add_gin_index(*args, **options) : Nil
      execute_batch(add_gin_index_statements(*args, **options))
    end
  end
end

abstract class Grant::Base
  # Declares a GIN index on an array or JSON column; `Model.migrator.create`
  # builds it (PostgreSQL only). Takes the options of `index`.
  #
  # ```
  # class Post < Grant::Base
  #   column tags : Array(String)?
  #   gin_index :tags
  # end
  # ```
  macro gin_index(columns, **options)
    index {{columns}}, using: :gin{{", ".id if options.size > 0}}{{options.double_splat}}
  end
end
