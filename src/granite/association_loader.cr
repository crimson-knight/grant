module Granite
  class AssociationLoader
    def self.load_associations(records : Array(Granite::Base), associations : Array(Symbol | Hash(Symbol, Array(Symbol))))
      return if records.empty? || associations.empty?
      
      associations.each do |association|
        case association
        when Symbol
          load_single_association(records, association)
        when Hash
          association.each do |name, nested|
            load_single_association(records, name)
            # Load nested associations on the loaded records
            nested_records = records.flat_map { |r| extract_association_records(r, name) }.compact
            load_associations(nested_records, nested)
          end
        end
      end
    end
    
    private def self.load_single_association(records : Array(Granite::Base), association_name : Symbol)
      return if records.empty?
      
      # Get association metadata from first record
      first_record = records.first
      association_meta = get_association_metadata(first_record, association_name)
      
      return unless association_meta
      
      case association_meta[:type]
      when :belongs_to
        load_belongs_to(records, association_name, association_meta)
      when :has_one
        load_has_one(records, association_name, association_meta)
      when :has_many
        load_has_many(records, association_name, association_meta)
      end
    end
    
    private def self.load_belongs_to(records : Array(Granite::Base), association_name : Symbol, meta : NamedTuple)
      # Collect all foreign key values
      foreign_key = meta[:foreign_key]
      foreign_key_values = records.map { |r| r.read_attribute(foreign_key) }.compact.uniq
      
      return if foreign_key_values.empty?
      
      # Load all associated records in one query
      target_class = meta[:target_class]
      primary_key = meta[:primary_key]
      
      associated_records = target_class.where(primary_key => foreign_key_values).all
      
      # Create lookup hash
      lookup = {} of Granite::Columns::Type => Granite::Base
      associated_records.each do |record|
        lookup[record.read_attribute(primary_key)] = record
      end
      
      # Assign to each record
      records.each do |record|
        fk_value = record.read_attribute(foreign_key)
        associated = lookup[fk_value]?
        record.set_loaded_association(association_name, associated)
      end
    end
    
    private def self.load_has_one(records : Array(Granite::Base), association_name : Symbol, meta : NamedTuple)
      # Similar to has_many but expecting single result per record
      primary_key = meta[:primary_key]
      primary_key_values = records.map { |r| r.read_attribute(primary_key) }.compact.uniq
      
      return if primary_key_values.empty?
      
      target_class = meta[:target_class]
      foreign_key = meta[:foreign_key]
      
      associated_records = target_class.where(foreign_key => primary_key_values).all
      
      # Group by foreign key
      grouped = {} of Granite::Columns::Type => Granite::Base
      associated_records.each do |record|
        fk_value = record.read_attribute(foreign_key)
        grouped[fk_value] = record # Only keep last one for has_one
      end
      
      # Assign to each record
      records.each do |record|
        pk_value = record.read_attribute(primary_key)
        associated = grouped[pk_value]?
        record.set_loaded_association(association_name, associated)
      end
    end
    
    private def self.load_has_many(records : Array(Granite::Base), association_name : Symbol, meta : NamedTuple)
      primary_key = meta[:primary_key]
      primary_key_values = records.map { |r| r.read_attribute(primary_key) }.compact.uniq
      
      return if primary_key_values.empty?
      
      target_class = meta[:target_class]
      foreign_key = meta[:foreign_key]
      through = meta[:through]?
      
      if through
        # Handle has_many through
        load_has_many_through(records, association_name, meta)
      else
        # Direct has_many
        associated_records = target_class.where(foreign_key => primary_key_values).all
        
        # Group by foreign key
        grouped = {} of Granite::Columns::Type => Array(Granite::Base)
        associated_records.each do |record|
          fk_value = record.read_attribute(foreign_key)
          grouped[fk_value] ||= [] of Granite::Base
          grouped[fk_value] << record
        end
        
        # Assign to each record
        records.each do |record|
          pk_value = record.read_attribute(primary_key)
          associated = grouped[pk_value]? || [] of Granite::Base
          record.set_loaded_association(association_name, associated.as(Array(Granite::Base)))
        end
      end
    end
    
    private def self.load_has_many_through(records : Array(Granite::Base), association_name : Symbol, meta : NamedTuple)
      # TODO: Implement has_many through eager loading
      # This is more complex and requires joining through the intermediate table
    end
    
    private def self.get_association_metadata(record : Granite::Base, association_name : Symbol)
      # Use macro-generated method to get metadata
      method_name = "_#{association_name}_association_meta"
      if record.class.responds_to?(method_name)
        meta = record.class.{{method_name.id}}
        # Convert to the format expected by the loader
        {
          type: meta[:type],
          target_class: get_class_from_name(meta[:target_class_name]),
          foreign_key: meta[:foreign_key],
          primary_key: meta[:primary_key],
          through: meta[:through]
        }
      else
        nil
      end
    end
    
    private def self.get_class_from_name(class_name : String)
      # This is a simplified version - in reality we'd need a proper class lookup
      # For now, this would need to be implemented based on your application's structure
      raise "Class lookup not implemented for #{class_name}"
    end
    
    private def self.extract_association_records(record : Granite::Base, association_name : Symbol)
      data = record.get_loaded_association(association_name)
      case data
      when Array(Granite::Base)
        data
      when Granite::Base
        [data]
      else
        [] of Granite::Base
      end
    end
  end
end