# A collection wrapper for already-loaded associations
# This provides the same interface as AssociationCollection but uses pre-loaded data
class Granite::LoadedAssociationCollection(Owner, Target)
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
    find(value) || raise Granite::Querying::NotFound.new("No record found with primary key = #{value}")
  end
  
  def find_by(**args)
    @records.find do |record|
      args.all? do |key, value|
        record.read_attribute(key.to_s) == value
      end
    end
  end
  
  def find_by!(**args)
    find_by(**args) || raise Granite::Querying::NotFound.new("No record found where #{args.map { |k, v| "#{k} = #{v}" }.join(" and ")}")
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