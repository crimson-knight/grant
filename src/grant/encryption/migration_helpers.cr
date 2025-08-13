module Grant::Encryption
  # Helpers for migrating data to/from encrypted columns
  module MigrationHelpers
    # Encrypt existing data in a column
    # Example:
    #   Grant::Encryption::MigrationHelpers.encrypt_column(
    #     User,
    #     :ssn,
    #     batch_size: 1000
    #   )
    def self.encrypt_column(
      model_class : Grant::Base.class,
      attribute : Symbol,
      batch_size : Int32 = 100,
      progress : Bool = true
    )
      attribute_str = attribute.to_s
      encrypted_column = "#{attribute_str}_encrypted"
      
      # Verify the model has the encrypted attribute
      unless model_class.encrypted_attributes.has_key?(attribute_str)
        raise ArgumentError.new("#{model_class} does not have encrypted attribute #{attribute}")
      end
      
      # Get total count
      total = model_class.count
      processed = 0
      
      puts "Encrypting #{total} records..." if progress
      
      # Process in batches
      offset = 0
      loop do
        records = model_class.limit(batch_size).offset(offset).select
        break if records.empty?
        
        records.each do |record|
          # Skip if already encrypted
          if record.read_attribute(encrypted_column)
            processed += 1
            next
          end
          
          # Get the unencrypted value
          unencrypted_value = record.read_attribute(attribute_str)
          next if unencrypted_value.nil?
          
          # Encrypt and set the value directly
          encrypted_value = Grant::Encryption.encrypt(
            unencrypted_value.as(String),
            model_class.name,
            attribute_str,
            model_class.encrypted_attributes[attribute_str].deterministic
          )
          record.write_attribute("#{attribute_str}_encrypted", encrypted_value)
          record.save!(validate: false)
          
          processed += 1
        end
        
        if progress
          percent = (processed.to_f / total * 100).round(2)
          print "\rProgress: #{processed}/#{total} (#{percent}%)    "
        end
        
        offset += batch_size
      end
      
      puts "\nEncryption complete!" if progress
      processed
    end
    
    # Decrypt data back to plain column (for rollback)
    # Example:
    #   Grant::Encryption::MigrationHelpers.decrypt_column(
    #     User,
    #     :ssn,
    #     target_column: :ssn_plain
    #   )
    def self.decrypt_column(
      model_class : Grant::Base.class,
      attribute : Symbol,
      target_column : Symbol? = nil,
      batch_size : Int32 = 100,
      progress : Bool = true
    )
      attribute_str = attribute.to_s
      encrypted_column = "#{attribute_str}_encrypted"
      target = target_column || attribute
      
      # Verify the model has the encrypted attribute
      unless model_class.encrypted_attributes.has_key?(attribute_str)
        raise ArgumentError.new("#{model_class} does not have encrypted attribute #{attribute}")
      end
      
      # Get total count
      total = model_class.count
      processed = 0
      
      puts "Decrypting #{total} records..." if progress
      
      # Process in batches
      offset = 0
      loop do
        records = model_class.limit(batch_size).offset(offset).select
        break if records.empty?
        
        records.each do |record|
          # Get the encrypted value
          encrypted_value = record.read_attribute("#{attribute_str}_encrypted")
          next if encrypted_value.nil?
          
          # Decrypt the value
          decrypted_value = Grant::Encryption.decrypt(
            encrypted_value.as(String),
            model_class.name,
            attribute_str
          )
          next if decrypted_value.nil?
          
          # Write to target column
          record.write_attribute(target.to_s, decrypted_value)
          record.save!(validate: false)
          
          processed += 1
        end
        
        if progress
          percent = (processed.to_f / total * 100).round(2)
          print "\rProgress: #{processed}/#{total} (#{percent}%)    "
        end
        
        offset += batch_size
      end
      
      puts "\nDecryption complete!" if progress
      processed
    end
    
    # Re-encrypt data with new keys (key rotation)
    # Example:
    #   # Set new keys first
    #   Grant::Encryption.configure do |config|
    #     config.primary_key = new_primary_key
    #     config.deterministic_key = new_deterministic_key
    #   end
    #   
    #   # Then rotate
    #   Grant::Encryption::MigrationHelpers.rotate_encryption(
    #     User,
    #     :ssn,
    #     old_keys: {
    #       primary: old_primary_key,
    #       deterministic: old_deterministic_key
    #     }
    #   )
    def self.rotate_encryption(
      model_class : Grant::Base.class,
      attribute : Symbol,
      old_keys : NamedTuple(primary: String, deterministic: String?),
      batch_size : Int32 = 100,
      progress : Bool = true
    )
      attribute_str = attribute.to_s
      encrypted_attr = model_class.encrypted_attributes[attribute_str]
      
      # Save current keys
      current_primary = KeyProvider.primary_key
      current_deterministic = KeyProvider.deterministic_key
      
      # Get total count
      total = model_class.count
      processed = 0
      
      puts "Rotating encryption keys for #{total} records..." if progress
      
      begin
        # Process in batches
        offset = 0
        loop do
          records = model_class.limit(batch_size).offset(offset).select
          break if records.empty?
          
          records.each do |record|
            encrypted_value = record.read_attribute("#{attribute_str}_encrypted")
            next if encrypted_value.nil?
            
            # Decrypt with old keys
            KeyProvider.primary_key = old_keys[:primary]
            KeyProvider.deterministic_key = old_keys[:deterministic] if encrypted_attr.deterministic && old_keys[:deterministic]
            
            decrypted = Grant::Encryption.decrypt(
              encrypted_value.as(String),
              model_class.name,
              attribute_str
            )
            
            # Re-encrypt with new keys
            KeyProvider.primary_key = current_primary
            KeyProvider.deterministic_key = current_deterministic if current_deterministic
            
            new_encrypted = Grant::Encryption.encrypt(
              decrypted,
              model_class.name,
              attribute_str,
              encrypted_attr.deterministic
            )
            
            record.write_attribute("#{attribute_str}_encrypted", new_encrypted)
            record.save!(validate: false)
            
            processed += 1
          end
          
          if progress
            percent = (processed.to_f / total * 100).round(2)
            print "\rProgress: #{processed}/#{total} (#{percent}%)    "
          end
          
          offset += batch_size
        end
        
        puts "\nKey rotation complete!" if progress
        processed
      ensure
        # Restore current keys
        KeyProvider.primary_key = current_primary
        KeyProvider.deterministic_key = current_deterministic if current_deterministic
      end
    end
    
    # Generate migration code for adding encrypted columns
    # Example:
    #   puts Grant::Encryption::MigrationHelpers.generate_migration(User, :ssn)
    def self.generate_migration(model_class : Grant::Base.class, attribute : Symbol) : String
      table_name = model_class.table_name
      column_name = "#{attribute}_encrypted"
      
      <<-MIGRATION
      # Add encrypted column for #{attribute}
      alter_table :#{table_name} do
        add_column :#{column_name}, :text
        add_index :#{column_name} if deterministic # Only for deterministic encryption
      end
      
      # Encrypt existing data
      Grant::Encryption::MigrationHelpers.encrypt_column(
        #{model_class.name},
        :#{attribute}
      )
      
      # Optional: Remove original column after verification
      # alter_table :#{table_name} do
      #   drop_column :#{attribute}
      # end
      MIGRATION
    end
  end
end