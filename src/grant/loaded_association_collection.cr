# A collection wrapper for already-loaded associations
# This provides the same interface as AssociationCollection but uses pre-loaded data
class Grant::LoadedAssociationCollection(Owner, Target)
  include Enumerable(Target)
  
  def initialize(@records : Array(Target))
  end
  
  def all(clause = "", params = [] of DB::Any)
    # For loaded associations, we return the pre-loaded records
    # TODO: Apply clause filters if provided
    Collection(Target).new(->{ @records })
  end
  
  def size
    @records.size
  end
  
  def empty?
    @records.empty?
  end
  
  def any?
    !empty?
  end
  
  def first
    @records.first?
  end
  
  def first!
    @records.first
  end
  
  def last
    @records.last?
  end
  
  def last!
    @records.last
  end
  
  def each(&)
    @records.each do |record|
      yield record
    end
  end
  
  def find(value)
    @records.find { |r| r.primary_key_value == value }
  end
  
  def find!(value)
    find(value) || raise Grant::Querying::NotFound.new("No record found with primary key = #{value}")
  end
  
  def find_by(**args)
    @records.find do |record|
      args.to_h.all? do |key, value|
        record.read_attribute(key.to_s) == value
      end
    end
  end
  
  def find_by!(**args)
    find_by(**args) || raise Grant::Querying::NotFound.new("No record found where #{args.map { |k, v| "#{k} = #{v}" }.join(" and ")}")
  end
  
  def where(**args)
    filtered = @records.select do |record|
      args.all? do |key, value|
        record.read_attribute(key.to_s) == value
      end
    end
    self.class.new(filtered)
  end
  
  def to_a
    @records
  end

  # Build a new record — not supported on pre-loaded collections.
  # Call the association method without eager loading to use build.
  def build(**attrs) : Target
    raise "Cannot build on a pre-loaded association collection. Use the association method without eager loading."
  end

  # Create a new record — not supported on pre-loaded collections.
  def create(**attrs) : Target
    raise "Cannot create on a pre-loaded association collection. Use the association method without eager loading."
  end

  # Create a new record or raise — not supported on pre-loaded collections.
  def create!(**attrs) : Target
    raise "Cannot create! on a pre-loaded association collection. Use the association method without eager loading."
  end

  # Delete all records via SQL — not supported on pre-loaded collections.
  def delete_all : Int64
    raise "Cannot delete_all on a pre-loaded association collection. Use the association method without eager loading."
  end

  # Destroy all records with callbacks — not supported on pre-loaded collections.
  def destroy_all : Int32
    raise "Cannot destroy_all on a pre-loaded association collection. Use the association method without eager loading."
  end
  
  def includes(*associations)
    # Already loaded, just return self
    self
  end
  
  def preload(*associations)
    # Already loaded, just return self
    self
  end
  
  def eager_load(*associations)
    # Already loaded, just return self
    self
  end
end