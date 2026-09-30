require "./table_definition"

module Grant::Schema
  # Raised when a migration name or attribute cannot be parsed.
  class GeneratorError < Grant::ErrorBase
  end

  # Parses migration names and attribute lists the way `rails generate
  # migration` does, and renders the migration source. The CLI (amber_cli) calls
  # this, so the DSL and the generated code stay in sync.
  #
  # ```
  # plan = Grant::Schema::Generator.parse("AddEmailToUsers", ["email:string:index"])
  # plan.steps.map(&.method) # => ["add_column", "add_index"]
  # Grant::Schema::Generator.render("AddEmailToUsers", ["email:string:index"], 20260930120000_i64)
  # ```
  #
  # Name conventions, matched on the underscored name:
  #
  # * `CreateUsers` creates the `users` table with the attributes and timestamps.
  # * `AddEmailToUsers` / `AddEmailAndAgeToUsers` adds each attribute to `users`.
  # * `RemoveEmailFromUsers` removes each attribute from `users`.
  # * `CreateJoinTableUsersGroups` creates the join table of `users` and `groups`.
  # * Any other name gives an empty `change`.
  #
  # An attribute is `name[:type[{limit}|{precision,scale}|{polymorphic}]][:index|:uniq]`;
  # the type defaults to `string`. `references` and `belongs_to` add a
  # `<name>_id` column, an index and a foreign key.
  class Generator
    enum Kind
      CreateTable
      AddColumns
      RemoveColumns
      CreateJoinTable
      Blank
    end

    # One attribute of the command line.
    struct Attribute
      getter name : ::String
      getter type : ::String
      getter limit : Int32?
      getter precision : Int32?
      getter scale : Int32?
      getter? polymorphic : Bool
      getter? index : Bool
      getter? unique : Bool

      def initialize(@name : ::String, @type : ::String = "string", @limit : Int32? = nil,
                     @precision : Int32? = nil, @scale : Int32? = nil, @polymorphic : Bool = false,
                     @index : Bool = false, @unique : Bool = false)
      end

      def reference? : Bool
        @type == "references" || @type == "belongs_to"
      end

      # The `limit:`/`precision:`/`scale:` arguments of the column call.
      def options : Array(::String)
        result = [] of ::String
        result << "limit: #{@limit}" if @limit
        result << "precision: #{@precision}" if @precision
        result << "scale: #{@scale}" if @scale
        result
      end
    end

    # One call of the generated `change` body, for example
    # `add_column :users, :email, :string`. Block steps (`create_table`) carry
    # their inner lines.
    struct Step
      getter method : ::String
      getter arguments : Array(::String)
      getter block_lines : Array(::String)
      getter block_variable : ::String?

      def initialize(@method : ::String, @arguments : Array(::String),
                     @block_lines : Array(::String) = [] of ::String, @block_variable : ::String? = nil)
      end

      def render(io : IO, indent : ::String) : Nil
        io << indent << @method << ' ' << @arguments.join(", ")
        if variable = @block_variable
          io << " do |" << variable << "|\n"
          @block_lines.each { |line| io << indent << "  " << line << '\n' }
          io << indent << "end\n"
        else
          io << '\n'
        end
      end
    end

    # The parsed migration: what it is called, what it does, which steps it has.
    struct Plan
      getter class_name : ::String
      getter file_stem : ::String
      getter kind : Kind
      getter table : ::String
      getter attributes : Array(Attribute)
      getter steps : Array(Step)

      def initialize(@class_name : ::String, @file_stem : ::String, @kind : Kind, @table : ::String,
                     @attributes : Array(Attribute), @steps : Array(Step))
      end

      # The migration class source for *version*.
      def render(version : Int64) : ::String
        String.build do |io|
          io << "class " << @class_name << " < Grant::Schema::Migration\n"
          io << "  migration_version " << version << "\n\n"
          io << "  def change\n"
          @steps.each(&.render(io, "    "))
          io << "  end\n"
          io << "end\n"
        end
      end
    end

    COLUMN_TYPES = %w(string text integer smallint tinyint bigint boolean float double decimal datetime timestamp
      time date binary json jsonb uuid hstore citext inet cidr macaddr ltree money)

    # Parses *name* and *attributes* into a `Plan`.
    def self.parse(name : ::String, attributes : Array(::String) = [] of ::String) : Plan
      raise GeneratorError.new("A migration needs a name") if name.strip.empty?
      underscored = name.strip.underscore
      raise GeneratorError.new("'#{name}' is not a valid migration name") unless underscored.matches?(/\A[a-z][a-z0-9_]*\z/)
      class_name = underscored.camelcase
      parsed = attributes.map { |text| parse_attribute(text) }
      ensure_unique(parsed)

      if match = underscored.match(/\Acreate_join_table_(.+)\z/)
        tables = match[1].split('_').reject(&.empty?)
        raise GeneratorError.new("'#{name}' must name two tables, for example CreateJoinTableUsersGroups") if tables.size < 2
        steps = [Step.new("create_join_table", tables.map { |table| ":#{table}" })]
        Plan.new(class_name, underscored, Kind::CreateJoinTable, tables.join('_'), parsed, steps)
      elsif match = underscored.match(/\Acreate_(.+)\z/)
        table = match[1]
        Plan.new(class_name, underscored, Kind::CreateTable, table, parsed, [create_table_step(table, parsed)])
      elsif (split = split_on(underscored, "add_", "_to_")) && !split[0].empty?
        table = split[1]
        steps = parsed.flat_map { |attribute| add_steps(table, attribute) }
        Plan.new(class_name, underscored, Kind::AddColumns, table, parsed, steps)
      elsif (split = split_on(underscored, "remove_", "_from_")) && !split[0].empty?
        table = split[1]
        steps = parsed.map { |attribute| remove_step(table, attribute) }
        Plan.new(class_name, underscored, Kind::RemoveColumns, table, parsed, steps)
      else
        Plan.new(class_name, underscored, Kind::Blank, "", parsed, [] of Step)
      end
    end

    # The migration source for *name*, versioned *version* (a timestamp number
    # or a `Time`, which is formatted as UTC `YYYYMMDDHHMMSS`).
    def self.render(name : ::String, attributes : Array(::String) = [] of ::String, version : Int64 | Time = Time.utc) : ::String
      parse(name, attributes).render(version_number(version))
    end

    # `20260930120000`-style version of *time*.
    def self.version_number(version : Int64 | Time) : Int64
      version.is_a?(Time) ? version.to_utc.to_s("%Y%m%d%H%M%S").to_i64 : version
    end

    # The file name `<version>_<snake_name>.cr`.
    def self.file_name(name : ::String, version : Int64 | Time = Time.utc) : ::String
      "#{version_number(version)}_#{parse(name).file_stem}.cr"
    end

    # Parses `name:type{options}:index|uniq`.
    def self.parse_attribute(text : ::String) : Attribute
      parts = text.strip.split(':')
      name = parts.shift
      raise GeneratorError.new("Attribute '#{text}' needs a name") unless name.matches?(/\A[a-z_][a-z0-9_]*\z/)
      type = "string"
      limit = precision = scale = nil.as(Int32?)
      polymorphic = index = unique = false
      unless parts.empty?
        head = parts.first
        unless {"index", "uniq", "unique"}.includes?(head)
          parts.shift
          if match = head.match(/\A([a-z_0-9]+)(?:\{(.*)\})?\z/)
            type = match[1]
            option = match[2]?
            if option
              if option == "polymorphic"
                polymorphic = true
              elsif pair = option.match(/\A(\d+),\s*(\d+)\z/)
                precision = pair[1].to_i
                scale = pair[2].to_i
              elsif option.matches?(/\A\d+\z/)
                number = option.to_i
                type == "decimal" ? (precision = number) : (limit = number)
              else
                raise GeneratorError.new("Attribute '#{text}' has unknown options {#{option}}")
              end
            end
          else
            raise GeneratorError.new("Attribute '#{text}' has an invalid type '#{head}'")
          end
        end
      end
      parts.each do |flag|
        case flag
        when "index"          then index = true
        when "uniq", "unique" then index = unique = true
        else                       raise GeneratorError.new("Attribute '#{text}' has unknown modifier '#{flag}'")
        end
      end
      unless type == "references" || type == "belongs_to" || COLUMN_TYPES.includes?(type)
        raise GeneratorError.new("Attribute '#{text}' has unknown type '#{type}'; use #{COLUMN_TYPES.join(", ")}, references or belongs_to")
      end
      Attribute.new(name, type, limit, precision, scale, polymorphic, index, unique)
    end

    private def self.ensure_unique(attributes : Array(Attribute)) : Nil
      seen = Set(::String).new
      attributes.each do |attribute|
        raise GeneratorError.new("Attribute '#{attribute.name}' is given twice") unless seen.add?(attribute.name)
      end
    end

    # `{attributes, table}` of `<prefix>a_b<separator>table`, or nil.
    private def self.split_on(name : ::String, prefix : ::String, separator : ::String) : {::String, ::String}?
      return nil unless name.starts_with?(prefix)
      body = name[prefix.size..]
      head, found, tail = body.rpartition(separator)
      return nil if found.empty? || tail.empty?
      {head, tail}
    end

    private def self.create_table_step(table : ::String, attributes : Array(Attribute)) : Step
      lines = [] of ::String
      indexes = [] of ::String
      attributes.each do |attribute|
        if attribute.reference?
          options = attribute.polymorphic? ? ["polymorphic: true"] : ["foreign_key: true"]
          lines << "t.references #{([":#{attribute.name}"] + options).join(", ")}"
        else
          lines << "t.#{attribute.type} #{([":#{attribute.name}"] + attribute.options).join(", ")}"
          if attribute.index?
            indexes << "t.index :#{attribute.name}#{attribute.unique? ? ", unique: true" : ""}"
          end
        end
      end
      lines.concat(indexes)
      lines << "t.timestamps"
      Step.new("create_table", [":#{table}"], lines, "t")
    end

    private def self.add_steps(table : ::String, attribute : Attribute) : Array(Step)
      if attribute.reference?
        options = attribute.polymorphic? ? ["polymorphic: true"] : ["foreign_key: true"]
        return [Step.new("add_reference", [":#{table}", ":#{attribute.name}"] + options)]
      end
      steps = [Step.new("add_column", [":#{table}", ":#{attribute.name}", ":#{attribute.type}"] + attribute.options)]
      if attribute.index?
        arguments = [":#{table}", ":#{attribute.name}"]
        arguments << "unique: true" if attribute.unique?
        steps << Step.new("add_index", arguments)
      end
      steps
    end

    private def self.remove_step(table : ::String, attribute : Attribute) : Step
      if attribute.reference?
        options = attribute.polymorphic? ? ["polymorphic: true"] : ["foreign_key: true"]
        return Step.new("remove_reference", [":#{table}", ":#{attribute.name}"] + options)
      end
      Step.new("remove_column", [":#{table}", ":#{attribute.name}", ":#{attribute.type}"] + attribute.options)
    end
  end
end
