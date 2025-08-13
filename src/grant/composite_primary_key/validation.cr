module Grant::CompositePrimaryKey::Validation
  # Validates uniqueness of composite primary key
  def validate_composite_key_uniqueness : Bool
    return true unless self.class.composite_primary_key?
    return true unless new_record? # Only validate on create
    
    pk_columns = self.class.composite_key.not_nil!.columns
    pk_values = primary_key_values
    
    # Skip validation if any part of the key is nil
    return true if pk_values.values.any?(&.nil?)
    
    # Build WHERE clause
    where_clause = pk_columns.map { |col| "#{self.class.quote(col.to_s)} = ?" }.join(" AND ")
    where_values = pk_columns.map { |col| pk_values[col.to_s] }
    
    # Check if a record already exists with this composite key
    !self.class.adapter.exists?(self.class.table_name, where_clause, where_values)
  end
  
  # Validates that all parts of composite key are present
  def validate_composite_key_presence : Bool
    return true unless self.class.composite_primary_key?
    return true unless new_record? # Only validate on create for non-auto keys
    
    pk_columns = self.class.composite_key.not_nil!.columns
    valid = true
    
    pk_columns.each do |col_sym|
      col = col_sym.to_s
      value = read_attribute(col)
      
      # Check if this is an auto-generated field
      is_auto = false
      {% begin %}
        {% for ivar in @type.instance_vars.select { |iv| (ann = iv.annotation(Grant::Column)) && ann[:primary] } %}
          {% ann = ivar.annotation(Grant::Column) %}
          if col == {{ivar.name.stringify}} && {{ann[:auto]}}
            is_auto = true
          end
        {% end %}
      {% end %}
      
      # Only validate non-auto fields
      if !is_auto && value.nil?
        valid = false
      end
    end
    
    valid
  end
  
  # Hook into the validation lifecycle
  macro included
    # Add composite key validations to the validation chain
    validate :base, "Composite key parts must be present" do |model|
      model.validate_composite_key_presence
    end
    
    validate :base, "Composite key must be unique" do |model|
      model.validate_composite_key_uniqueness
    end
  end
  
  # Helper method to check if composite key is complete
  def composite_key_complete? : Bool
    return true unless self.class.composite_primary_key?
    
    pk_values = primary_key_values
    !pk_values.values.any?(&.nil?)
  end
  
  # Helper to get a string representation of the composite key
  def composite_key_string : String?
    return nil unless self.class.composite_primary_key?
    return nil unless composite_key_complete?
    
    pk_values = primary_key_values
    pk_values.map { |k, v| "#{k}=#{v}" }.join(", ")
  end
end