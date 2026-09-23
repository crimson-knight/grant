# A collection wrapper for already-loaded associations.
#
# Generated associations provide an owner and foreign-key context so mutation
# methods persist changes just like `Grant::AssociationCollection`. The
# records-only constructor remains available for read-only snapshots.
class Grant::LoadedAssociationCollection(Owner, Target)
  include Enumerable(Target)

  def initialize(@records : Array(Target))
    @association_owner = nil.as(Owner?)
    @foreign_key = nil.as(String?)
    @type_column = nil.as(String?)
    @primary_key = nil.as(String?)
  end

  def initialize(@records : Array(Target), owner : Owner,
                 foreign_key : String, type_column : String? = nil,
                 primary_key : String = Owner.primary_name)
    @association_owner = owner
    @foreign_key = foreign_key
    @type_column = type_column
    @primary_key = primary_key
  end

  def all(clause = "", params = [] of DB::Any)
    Collection(Target).new(-> { @records })
  end

  def size : Int32
    @records.size
  end

  def empty? : Bool
    @records.empty?
  end

  def any? : Bool
    !empty?
  end

  def first : Target?
    @records.first?
  end

  def first! : Target
    @records.first
  end

  def last : Target?
    @records.last?
  end

  def last! : Target
    @records.last
  end

  def each(&block : Target ->)
    @records.each { |record| yield record }
  end

  def find(value) : Target?
    @records.find { |record| record.primary_key_value == value }
  end

  def find!(value) : Target
    find(value) || raise Grant::Querying::NotFound.new("No record found with primary key = #{value}")
  end

  def find_by(**args) : Target?
    @records.find do |record|
      args.to_h.all? { |key, value| record.read_attribute(key.to_s) == value }
    end
  end

  def find_by!(**args) : Target
    find_by(**args) || raise Grant::Querying::NotFound.new("No record found where #{args.map { |key, value| "#{key} = #{value}" }.join(" and ")}")
  end

  def where(**args)
    filtered = @records.select do |record|
      args.to_h.all? { |key, value| record.read_attribute(key.to_s) == value }
    end
    if association_owner = @association_owner
      if key = @foreign_key
        return self.class.new(filtered, association_owner, key, @type_column, @primary_key || Owner.primary_name)
      end
    end
    self.class.new(filtered)
  end

  def to_a : Array(Target)
    @records
  end

  def build(**attrs) : Target
    record = Target.new
    record.set_attributes(attrs.to_h.transform_keys(&.to_s))
    assign_to_owner(record)
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

  def <<(record : Target) : self
    association_owner = owner
    owner_value = association_owner.read_attribute(primary_key)
    key_changed = record.read_attribute(foreign_key) != owner_value
    type_changed = type_column ? record.read_attribute(type_column.not_nil!) != association_owner.class.name : false
    assign_to_owner(record)
    if association_owner.persisted? && (!record.persisted? || key_changed || type_changed)
      record.save!
    end
    @records << record unless @records.includes?(record)
    self
  end

  def append(*records : Target) : self
    records.each { |record| self << record }
    self
  end

  def push(*records : Target) : self
    append(*records)
  end

  def delete(*records : Target) : Array(Target)
    removed = [] of Target
    records.each do |record|
      associated_record = find(record.primary_key_value)
      next unless associated_record
      associated_record.write_attribute(foreign_key, nil)
      if column = type_column
        associated_record.write_attribute(column, nil)
      end
      associated_record.save!
      @records.delete(associated_record)
      removed << associated_record
    end
    removed
  end

  def destroy(*records : Target) : Array(Target)
    removed = [] of Target
    records.each do |record|
      associated_record = find(record.primary_key_value)
      next unless associated_record
      if associated_record.destroy!
        @records.delete(associated_record)
        removed << associated_record
      end
    end
    removed
  end

  def ids : Array(Grant::Columns::Type)
    @records.map(&.primary_key_value.as(Grant::Columns::Type))
  end

  def exists? : Bool
    !empty?
  end

  def exists?(value : Grant::Columns::Type) : Bool
    !find(value).nil?
  end

  def clear : self
    @records.dup.each { |record| delete(record) }
    self
  end

  def delete_all : Int64
    before = @records.size
    clear
    before.to_i64
  end

  def destroy_all : Int32
    destroy(*@records.dup).size
  end

  def includes(*associations)
    self
  end

  def preload(*associations)
    self
  end

  def eager_load(*associations)
    self
  end

  private def assign_to_owner(record : Target) : Nil
    association_owner = owner
    record.write_attribute(foreign_key, association_owner.read_attribute(primary_key))
    if column = type_column
      record.write_attribute(column, association_owner.class.name)
    end
  end

  private def owner : Owner
    @association_owner || raise ArgumentError.new("Association mutation requires owner and foreign-key context")
  end

  private def foreign_key : String
    @foreign_key || raise ArgumentError.new("Association mutation requires a foreign key")
  end

  private def type_column : String?
    @type_column
  end

  private def primary_key : String
    @primary_key || Owner.primary_name
  end
end
