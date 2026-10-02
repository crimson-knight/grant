require "./constraint_definition"
require "../counter_cache"

module Grant::Schema
  # Indexes, constraints, references and PostgreSQL column types of the
  # create-table DSL.
  class TableDefinition
    getter indexes = [] of IndexDefinition
    getter foreign_keys = [] of ForeignKeyDefinition
    getter check_constraints = [] of CheckConstraintDefinition
    getter unique_constraints = [] of UniqueConstraintDefinition
    getter exclusion_constraints = [] of ExclusionConstraintDefinition

    # Adds an index on *columns*; see `SchemaStatements#add_index` for the
    # options. The index is created right after the table.
    def index(columns : ColumnNames, name : ::String | Symbol? = nil, unique : Bool = false, where : ::String? = nil,
              using : ::String | Symbol? = nil, order = nil,
              opclass = nil,
              include covering : ColumnNames? = nil, length = nil,
              comment : ::String? = nil) : IndexDefinition
      definition = IndexDefinition.build(@name, columns, name, unique, where, using, order, opclass, covering, length, nil, false, comment)
      @indexes << definition
      definition
    end

    # Adds a foreign key from this table to *to_table*.
    def foreign_key(to_table : TableName, column : ColumnNames? = nil, primary_key : ColumnNames? = nil,
                    name : ::String | Symbol? = nil, on_delete : Symbol? = nil, on_update : Symbol? = nil,
                    deferrable : Bool | Symbol? = nil) : ForeignKeyDefinition
      definition = ForeignKeyDefinition.build(@name, to_table, column, primary_key, name, on_delete, on_update, deferrable)
      @foreign_keys << definition
      definition
    end

    # Adds `CHECK (expression)`.
    def check_constraint(expression : ::String, name : ::String | Symbol? = nil) : CheckConstraintDefinition
      definition = CheckConstraintDefinition.new(@name, expression, name.try(&.to_s))
      @check_constraints << definition
      definition
    end

    # Adds `UNIQUE (columns)`.
    def unique_constraint(columns : ColumnNames, name : ::String | Symbol? = nil,
                          deferrable : Bool | Symbol? = nil) : UniqueConstraintDefinition
      definition = UniqueConstraintDefinition.new(@name, IndexDefinition.to_names(columns), name.try(&.to_s), deferrable)
      @unique_constraints << definition
      definition
    end

    # Adds an exclusion constraint (PostgreSQL only).
    def exclusion_constraint(expression : ::String, using : ::String | Symbol? = nil, where : ::String? = nil,
                             name : ::String | Symbol? = nil, deferrable : Bool | Symbol? = nil) : ExclusionConstraintDefinition
      definition = ExclusionConstraintDefinition.new(@name, expression, using.try(&.to_s), where, name.try(&.to_s), deferrable)
      @exclusion_constraints << definition
      definition
    end

    # Adds the `<name>_id` column (and `<name>_type` when *polymorphic*) of a
    # reference, with an index by default and a foreign key on request.
    #
    # ```
    # t.references :author, foreign_key: {to_table: :users, on_delete: :cascade}
    # t.references :commentable, polymorphic: true
    # ```
    #
    # *foreign_key* is `true` (the table is the plural of the name) or a named
    # tuple with `to_table`, `column`, `primary_key`, `name`, `on_delete`,
    # `on_update` and `deferrable`. A polymorphic reference has no foreign key.
    def references(*names : ::String | Symbol, polymorphic : Bool = false, null : Bool = true, index : Bool = true,
                   foreign_key : Bool | NamedTuple = false, type : Symbol = :bigint, default : DefaultLiteral | Unset = UNSET,
                   comment : ::String? = nil, unique : Bool = false) : Nil
      names.each do |name|
        column_name = "#{name}_id"
        column(column_name, type, null, default, nil, nil, nil, nil, comment)
        if polymorphic
          column("#{name}_type", :string, null)
        end
        if index
          index_columns = polymorphic ? ["#{name}_type", column_name] : [column_name]
          self.index(index_columns, unique: unique)
        end
        if foreign_key && !polymorphic
          add_reference_foreign_key(name.to_s, column_name, foreign_key)
        end
      end
    end

    # Alias of `#references`.
    def belongs_to(*names : ::String | Symbol, polymorphic : Bool = false, null : Bool = true, index : Bool = true,
                   foreign_key : Bool | NamedTuple = false, type : Symbol = :bigint, default : DefaultLiteral | Unset = UNSET,
                   comment : ::String? = nil, unique : Bool = false) : Nil
      references(*names, polymorphic: polymorphic, null: null, index: index, foreign_key: foreign_key, type: type,
        default: default, comment: comment, unique: unique)
    end

    private def add_reference_foreign_key(name : ::String, column_name : ::String, options : Bool | NamedTuple) : Nil
      to_table = Grant::CounterCache.pluralize(name)
      column = column_name
      primary_key = nil.as(::String | Symbol?)
      key_name = nil.as(::String | Symbol?)
      on_delete = nil.as(Symbol?)
      on_update = nil.as(Symbol?)
      deferrable = nil.as(Bool | Symbol?)
      unless options.is_a?(Bool)
        to_table = options[:to_table]?.try(&.to_s) || to_table
        column = options[:column]?.try(&.to_s) || column
        primary_key = options[:primary_key]?
        key_name = options[:name]?
        on_delete = options[:on_delete]?
        on_update = options[:on_update]?
        deferrable = options[:deferrable]?
      end
      foreign_key(to_table, column, primary_key, key_name, on_delete, on_update, deferrable)
    end

    # PostgreSQL-only column types. They raise `UnsupportedOperation` when the
    # statement is built for another dialect.
    {% for method, sql in {hstore: "hstore", citext: "citext", inet: "inet", cidr: "cidr", macaddr: "macaddr", ltree: "ltree", money: "money"} %}
      # Adds one or more `{{sql.id}}` columns (PostgreSQL; `{{sql.id}}` may need `enable_extension`).
      def {{method.id}}(*names : ::String | Symbol, null : Bool = true, default : DefaultLiteral | Unset = UNSET,
                        default_sql : ::String? = nil, comment : ::String? = nil, array : Bool = false) : Nil
        names.each do |name|
          column(name, {{sql}}, null, default, default_sql, nil, nil, nil, comment, nil, array).pg_only = true
        end
      end
    {% end %}

    # Adds a column of the PostgreSQL enum type *enum_type* (see `create_enum`).
    def enum(*names : ::String | Symbol, enum_type : ::String | Symbol, null : Bool = true,
             default : DefaultLiteral | Unset = UNSET, comment : ::String? = nil, array : Bool = false) : Nil
      names.each do |name|
        column(name, enum_type.to_s, null, default, nil, nil, nil, nil, comment, nil, array).pg_only = true
      end
    end
  end
end
