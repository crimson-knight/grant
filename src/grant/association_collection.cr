# Lazy, owner-scoped collection returned by a has_many association.
class Grant::AssociationCollection(Owner, Target)
  include Enumerable(Target)

  def initialize(@owner : Owner,
                 @foreign_key : (Symbol | String),
                 @through : (Symbol | String | Nil) = nil,
                 @primary_key : (Symbol | String | Nil) = nil,
                 @inverse_of : (Symbol | String | Nil) = nil,
                 @scope : (Grant::Query::Builder(Target) -> Grant::Query::Builder(Target))? = nil,
                 @association_name : String? = nil,
                 @loaded_records : Array(Target)? = nil,
                 @through_delete_all : Proc(Int64)? = nil,
                 @through_source : String? = nil)
  end

  def all(clause = "", params = [] of DB::Any) : Array(Target)
    if clause.empty? && params.empty? && (records = @loaded_records)
      return records
    end
    ensure_lazy_loading_allowed

    start_time = Time.instant
    results = if clause.empty? && params.empty?
                association_relation.select
              else
                scope_clause, scope_params, scope_modifiers = scope_fragments
                sql = [query, scope_clause, clause, scope_modifiers].reject(&.empty?).join(" ")
                all_params = [owner_key]
                scope_params.each { |value| all_params << value }
                params.each { |value| all_params << value.as(Grant::Columns::Type) }
                Target.raw_all(sql, all_params)
              end
    duration = Time.instant - start_time

    Grant::Logs::Association.info { "Loaded has_many association - #{Owner.name} [#{Target.name}] [fk: #{@foreign_key}] - #{results.size} records (#{duration.total_milliseconds}ms)" }

    if inverse = @inverse_of
      results.each { |record| record.set_loaded_association(inverse.to_s, owner) }
    end
    if clause.empty? && params.empty?
      loaded_records = results.dup
      @loaded_records = loaded_records
      if association_name = @association_name
        owner.set_loaded_association(association_name, loaded_records)
      end
    end
    results
  end

  def each(&block : Target ->)
    all.each { |record| yield record }
  end

  def to_a : Array(Target)
    all
  end

  # Returns the association size as `Int64`, using loaded records when present.
  def size : Int64
    if records = @loaded_records
      records.size.to_i64
    else
      count
    end
  end

  # Returns the database count within the owner's association scope without
  # hydrating records, even when the association target has already been loaded.
  # Returns `Int64`.
  def count : Int64
    ensure_lazy_loading_allowed
    result = association_relation.count
    result.is_a?(Int64) ? result : result.values.sum
  end

  # Loads the records and returns their number, matching Enumerable semantics.
  def length : Int32
    all.size
  end

  def empty? : Bool
    if records = @loaded_records
      records.empty?
    else
      ensure_lazy_loading_allowed
      !association_relation.exists?
    end
  end

  def any? : Bool
    if records = @loaded_records
      !records.empty?
    else
      ensure_lazy_loading_allowed
      association_relation.exists?
    end
  end

  def none? : Bool
    !any?
  end

  def first : Target?
    all.first?
  end

  def first! : Target
    all.first
  end

  def last : Target?
    all.last?
  end

  def last! : Target
    all.last
  end

  def where(**matches) : Grant::Query::Builder(Target)
    ensure_lazy_loading_allowed
    association_relation.where(**matches)
  end

  def find(value) : Target?
    record = if records = @loaded_records
               records.find { |item| item.primary_key_value == value }
             elsif @through
               ensure_lazy_loading_allowed
               all.find { |record| record.primary_key_value == value }
             else
               ensure_lazy_loading_allowed
               association_relation.where(Target.primary_name, :eq, value.as(Grant::Columns::Type)).first
             end
    set_inverse(record) if record
    record
  end

  def find!(value) : Target
    find(value) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{Target.primary_name} = #{value}")
  end

  def find_by(**args) : Target?
    record = if records = @loaded_records
               records.find do |record|
                 args.to_h.all? { |key, value| record.read_attribute(key.to_s) == value }
               end
             else
               ensure_lazy_loading_allowed
               association_relation.where(**args).first
             end
    set_inverse(record) if record
    record
  end

  def find_by!(**args) : Target
    find_by(**args) || raise Grant::Querying::NotFound.new("No #{Target.name} found where #{args.map { |key, value| "#{key} = #{value}" }.join(" and ")}")
  end

  def build(**attrs) : Target
    record = Target.new
    record.set_attributes(attrs.to_h.transform_keys(&.to_s))
    record.set_attributes({@foreign_key.to_s => owner_key}) if !@through && !owner_key.nil?
    @loaded_records.try do |records|
      records << record unless records.includes?(record)
      sync_loaded_association
    end
    record
  end

  def create(**attrs) : Target
    record = build(**attrs)
    record.save
    record
  end

  def create!(**attrs) : Target
    record = build(**attrs)
    record.save!
    record
  end

  # Associates *record* with this owner and persists it when the owner already
  # exists. Repeated appends of the same record do not issue another save.
  def <<(record : Target) : self
    raise ArgumentError.new("Cannot append to a has_many :through collection") if @through

    key_changed = record.read_attribute(@foreign_key.to_s) != owner_key
    if key_changed && !owner_key.nil?
      record.write_attribute(@foreign_key.to_s, owner_key)
    end
    record.save! if owner.persisted? && (key_changed || !record.persisted?)
    @loaded_records.try { |records| records << record unless records.includes?(record) }
    sync_loaded_association
    self
  end

  def append(*records : Target) : self
    records.each { |record| self << record }
    self
  end

  def push(*records : Target) : self
    append(*records)
  end

  # Disassociates matching records by nullifying their foreign key.
  def delete(*records : Target) : Array(Target)
    raise ArgumentError.new("Cannot delete targets through a has_many :through collection") if @through

    removed = [] of Target
    records.each do |record|
      associated_record = find(record.primary_key_value)
      next unless associated_record

      associated_record.write_attribute(@foreign_key.to_s, nil)
      associated_record.save!
      removed << associated_record
      @loaded_records.try(&.delete(associated_record))
      sync_loaded_association
    end
    removed
  end

  # Destroys matching records and runs their callbacks.
  def destroy(*records : Target) : Array(Target)
    removed = [] of Target
    records.each do |record|
      associated_record = find(record.primary_key_value)
      next unless associated_record
      delete(associated_record) if @through
      if associated_record.destroy!
        removed << associated_record
        @loaded_records.try(&.delete(associated_record))
        sync_loaded_association
      end
    end
    removed
  end

  def ids : Array(Grant::Columns::Type)
    all.map(&.primary_key_value.as(Grant::Columns::Type))
  end

  def exists? : Bool
    if records = @loaded_records
      !records.empty?
    elsif @through
      ensure_lazy_loading_allowed
      !all.empty?
    else
      ensure_lazy_loading_allowed
      association_relation.exists?
    end
  end

  def exists?(value : Grant::Columns::Type) : Bool
    !find(value).nil?
  end

  # Clears this association by disassociating its rows. Target records remain.
  def clear : self
    if @through
      delete_all
    else
      all.each { |record| delete(record) }
    end
    @loaded_records.try(&.clear)
    sync_loaded_association
    self
  end

  def destroy_all : Int32
    records = all
    records.count do |record|
      destroyed = record.destroy
      @loaded_records.try(&.delete(record)) if destroyed
      destroyed
    end
  end

  # Removes associated rows without callbacks. For a through association only
  # the join rows are deleted; the target records remain.
  def delete_all : Int64
    count = if callback = @through_delete_all
              callback.call
            elsif @through
              raise ArgumentError.new("Deleting this through association requires join metadata")
            else
              association_relation.delete_all
            end
    @loaded_records.try(&.clear)
    sync_loaded_association
    count
  end

  private getter owner

  private def set_inverse(record : Target) : Target
    if inverse = @inverse_of
      record.set_loaded_association(inverse.to_s, owner)
    end
    record
  end

  private def sync_loaded_association : Nil
    if association_name = @association_name
      if records = @loaded_records
        owner.set_loaded_association(association_name, records)
      end
    end
  end

  private def ensure_lazy_loading_allowed : Nil
    owner.assert_association_can_lazy_load!(@association_name || Target.name)
  end

  private def owner_key : Grant::Columns::Type
    owner.read_attribute(@primary_key || Owner.primary_name)
  end

  private def association_relation : Grant::Query::Builder(Target)
    relation = Target.current_scope
    if association_scope = @scope
      relation = association_scope.call(relation)
    end
    if @through
      through_metadata, source_metadata = through_associations
      if source_metadata[:type] == :belongs_to
        source_key = through_metadata[:target_class].quote(source_metadata[:foreign_key])
        target_key = source_metadata[:primary_key]
      else
        join_model = through_metadata[:target_class]
        primary_name = join_model.primary_name || raise Grant::Querying::MissingPrimaryKeyError.new("#{join_model.name} has no primary key")
        source_key = join_model.quote(primary_name)
        target_key = source_metadata[:foreign_key]
      end
      join_model = through_metadata[:target_class]
      join_table = join_model.quoted_table_name
      join_owner_key = join_model.quote(through_metadata[:foreign_key])
      subquery = "SELECT #{source_key} FROM #{join_table} WHERE #{join_owner_key} = ?"
      relation.where("#{Target.quote(target_key)} IN (#{subquery})", owner_key)
    else
      relation.where(@foreign_key.to_s, :eq, owner_key)
    end
  end

  private def through_associations : Tuple(Grant::AssociationRegistry::AssociationMeta, Grant::AssociationRegistry::AssociationMeta)
    through_name = @through || raise ArgumentError.new("Missing through association metadata")
    source_name = @through_source || raise ArgumentError.new("Missing source association metadata")
    through_metadata = Grant::AssociationRegistry.get(Owner.name, through_name.to_s) || raise ArgumentError.new("Cannot resolve through association #{Owner.name}##{through_name}")
    source_metadata = Grant::AssociationRegistry.get(through_metadata[:target_class].name, source_name) || raise ArgumentError.new("Cannot resolve source association #{through_metadata[:target_class].name}##{source_name}")
    {through_metadata, source_metadata}
  end

  private def scope_fragments : Tuple(String, Array(Grant::Columns::Type), String)
    return {"", [] of Grant::Columns::Type, ""} unless association_scope = @scope

    adapter = Target.adapter
    db_type = if adapter.postgres?
                Grant::Query::Builder::DbType::Pg
              elsif adapter.mysql?
                Grant::Query::Builder::DbType::Mysql
              else
                Grant::Query::Builder::DbType::Sqlite
              end
    builder = Grant::Query::Builder(Target).new(db_type)
    builder = association_scope.call(builder)
    clauses = [] of String
    params = [] of Grant::Columns::Type

    builder.where_fields.each do |field|
      if field.is_a?(NamedTuple(join: Symbol, field: String, operator: Symbol, value: Grant::Columns::Type))
        operator = SCOPE_OPERATORS[field[:operator].to_s]? || field[:operator].to_s
        column = field[:field]
        column = "#{Target.quote(Target.table_name)}.#{Target.quote(column)}" unless column.includes?(".")
        clauses << "#{column} #{operator} ?"
        params << field[:value]
      elsif field.is_a?(NamedTuple(join: Symbol, stmt: String, value: Grant::Columns::Type))
        clauses << "(#{field[:stmt]})"
        params << field[:value] unless field[:value].nil?
      end
    end

    where_clause = clauses.empty? ? "" : "AND #{clauses.join(" AND ")}"
    modifiers = [] of String
    unless builder.order_fields.empty?
      order_fields = builder.order_fields.map do |order|
        field = order[:field]
        quoted = field.includes?(".") ? field.split(".").map { |part| Target.quote(part) }.join(".") : Target.quote(field)
        direction = order[:direction] == Grant::Query::Builder::Sort::Descending ? "DESC" : "ASC"
        "#{quoted} #{direction}"
      end
      modifiers << "ORDER BY #{order_fields.join(", ")}"
    end
    modifiers << "LIMIT #{builder.limit}" if builder.limit
    modifiers << "OFFSET #{builder.offset}" if builder.offset
    {where_clause, params, modifiers.join(" ")}
  end

  private def query : String
    if @through.nil?
      "WHERE #{Target.quote(Target.table_name)}.#{Target.quote(@foreign_key.to_s)} = ?"
    else
      through_metadata, source_metadata = through_associations
      join_model = through_metadata[:target_class]
      join_table = join_model.quoted_table_name
      target_table = Target.quoted_table_name
      join_primary_name = join_model.primary_name || raise Grant::Querying::MissingPrimaryKeyError.new("#{join_model.name} has no primary key")
      join_primary_key = join_model.quote(join_primary_name)
      target_join = if source_metadata[:type] == :belongs_to
                      "#{target_table}.#{Target.quote(source_metadata[:primary_key])} = #{join_table}.#{join_model.quote(source_metadata[:foreign_key])}"
                    else
                      "#{target_table}.#{Target.quote(source_metadata[:foreign_key])} = #{join_table}.#{join_primary_key}"
                    end
      "JOIN #{join_table} ON #{target_join} WHERE #{join_table}.#{join_model.quote(through_metadata[:foreign_key])} = ?"
    end
  end

  SCOPE_OPERATORS = {"eq" => "=", "gteq" => ">=", "lteq" => "<=", "neq" => "!=", "ltgt" => "<>", "gt" => ">", "lt" => "<", "ngt" => "!>", "nlt" => "!<", "like" => "LIKE", "nlike" => "NOT LIKE"}
end
