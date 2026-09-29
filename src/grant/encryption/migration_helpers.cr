module Grant::Encryption
  # Helpers for migrating data to/from encrypted columns.
  #
  # Every helper walks the table in keyset batches (`WHERE pk > last ORDER BY
  # pk LIMIT n`), so a batch costs the same at row one and row a million and a
  # row whose value changes cannot be skipped or visited twice. Values are read
  # and written as raw column text, one bound `UPDATE` per changed row inside a
  # per-batch transaction: no model instances, validations, callbacks or
  # timestamps. All of them are idempotent, so an interrupted run can be
  # restarted.
  module MigrationHelpers
    alias RawRow = Tuple(Grant::Columns::Type, String?, String?)

    # Encrypts the plaintext held in a column.
    #
    # For a transparent attribute (`encrypts ssn : String`) the plaintext is in
    # the attribute's own column and is replaced in place. For the
    # `<attr>_encrypted` form the plaintext is read from *source_column*
    # (default: a column named like the attribute, which the model does not
    # declare) and the ciphertext is written to `<attr>_encrypted`. Rows that
    # already hold ciphertext are skipped. Plaintext for non-String types must
    # be in `Grant::Encryption::Serializer` form. Returns the number of rows
    # processed.
    #
    # ```
    # Grant::Encryption::MigrationHelpers.encrypt_column(User, :ssn, batch_size: 1000)
    # ```
    def self.encrypt_column(
      model_class : Grant::Base.class,
      attribute : Symbol,
      batch_size : Int32 = 100,
      progress : Bool = true,
      source_column : Symbol? = nil,
    ) : Int32
      attribute_str = attribute.to_s
      encrypted_attr = encrypted_attribute_for(model_class, attribute_str)
      destination = encrypted_attr.column_name
      source = (source_column || (encrypted_attr.transparent? ? destination : attribute)).to_s
      processed = 0

      each_batch(model_class, source, destination, batch_size, progress, "Encrypting") do |rows|
        changes = [] of Tuple(Grant::Columns::Type, String)
        rows.each do |key, plain, current|
          processed += 1
          next if plain.nil?
          next if encrypted_payload?(current) || (source == destination && encrypted_payload?(plain))
          changes << {key, encrypted_attr.seal(plain)}
        end
        write_batch(model_class, destination, changes)
      end

      Grant::Log.info { "Encryption complete!" } if progress
      processed
    end

    # Decrypts an encrypted column back to plaintext (a rollback). The
    # plaintext goes to *target_column*: for a transparent attribute the
    # attribute's own column by default; for the `<attr>_encrypted` form a
    # column named like the attribute, which must exist in the table. Rows
    # that do not hold ciphertext are skipped. Returns the number of rows
    # processed.
    #
    # ```
    # Grant::Encryption::MigrationHelpers.decrypt_column(User, :ssn, target_column: :ssn_plain)
    # ```
    def self.decrypt_column(
      model_class : Grant::Base.class,
      attribute : Symbol,
      target_column : Symbol? = nil,
      batch_size : Int32 = 100,
      progress : Bool = true,
    ) : Int32
      attribute_str = attribute.to_s
      encrypted_attr = encrypted_attribute_for(model_class, attribute_str)
      source = encrypted_attr.column_name
      target = (target_column || (encrypted_attr.transparent? ? source : attribute)).to_s
      processed = 0

      each_batch(model_class, source, target, batch_size, progress, "Decrypting") do |rows|
        changes = [] of Tuple(Grant::Columns::Type, String)
        rows.each do |key, stored, _current|
          next if stored.nil? || !encrypted_payload?(stored)
          changes << {key, encrypted_attr.open(stored)}
          processed += 1
        end
        write_batch(model_class, target, changes)
      end

      Grant::Log.info { "Decryption complete!" } if progress
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
    #
    # With `Config.primary_keys = [new, old]` and `previous:` schemes a rotation
    # needs no maintenance window (reads fall back to the old keys); run this
    # afterwards to move the remaining rows to the new key.
    def self.rotate_encryption(
      model_class : Grant::Base.class,
      attribute : Symbol,
      old_keys : NamedTuple(primary: String, deterministic: String?),
      old_salt : String? = nil,
      batch_size : Int32 = 100,
      progress : Bool = true,
    ) : Int32
      attribute_str = attribute.to_s
      encrypted_attr = encrypted_attribute_for(model_class, attribute_str)
      column = encrypted_attr.column_name

      # Capture current settings; rotation passes them explicitly rather than
      # swapping process-wide keys while application fibers may be encrypting.
      current_primary = KeyProvider.primary_key
      current_deterministic = KeyProvider.deterministic_key
      current_salt = KeyProvider.key_derivation_salt
      previous_salt = old_salt || current_salt
      previous_primary = KeyProvider.decode_key(old_keys[:primary])
      previous_deterministic = old_keys[:deterministic].try { |key| KeyProvider.decode_key(key) }
      processed = 0

      each_batch(model_class, column, column, batch_size, progress, "Rotating encryption keys for") do |rows|
        changes = [] of Tuple(Grant::Columns::Type, String)
        rows.each do |key, stored, _current|
          next if stored.nil?

          # First try the old configuration. If it fails, accept ciphertext
          # already rotated with the current configuration so interrupted
          # batches can resume safely.
          decrypted = begin
            Grant::Encryption.decrypt_with_keys(
              stored,
              model_class.name,
              attribute_str,
              previous_primary,
              previous_deterministic,
              previous_salt
            )
          rescue ex : Cipher::DecryptionError
            Grant::Encryption.decrypt_with_keys(
              stored,
              model_class.name,
              attribute_str,
              current_primary,
              current_deterministic,
              current_salt
            )
          end

          # Re-encrypt with new keys
          changes << {key, Grant::Encryption.encrypt_with_keys(
            decrypted,
            model_class.name,
            attribute_str,
            encrypted_attr.deterministic,
            current_primary,
            current_deterministic,
            current_salt
          )}
          processed += 1
        end
        write_batch(model_class, column, changes)
      end

      Grant::Log.info { "Key rotation complete!" } if progress
      processed
    end

    # Generate migration code for adding an encrypted column. A transparent
    # attribute needs its own column widened to text; the `<attr>_encrypted`
    # form needs the extra column (indexed when deterministic).
    # Example:
    #   puts Grant::Encryption::MigrationHelpers.generate_migration(User, :ssn)
    def self.generate_migration(model_class : Grant::Base.class, attribute : Symbol) : String
      table_name = model_class.table_name
      encrypted_attr = encrypted_attribute_for(model_class, attribute.to_s)
      column_name = encrypted_attr.column_name

      prepare = if encrypted_attr.transparent?
                  <<-PREPARE
                  # Store ciphertext as text in the existing column
                  alter_table :#{table_name} do
                    change_column :#{column_name}, :text
                    #{encrypted_attr.deterministic ? "add_index :#{column_name}" : "# not deterministic: not queryable, so not indexed"}
                  end
                  PREPARE
                else
                  <<-PREPARE
                  # Add encrypted column for #{attribute}
                  alter_table :#{table_name} do
                    add_column :#{column_name}, :text
                    #{encrypted_attr.deterministic ? "add_index :#{column_name}" : "# not deterministic: not queryable, so not indexed"}
                  end
                  PREPARE
                end

      <<-MIGRATION
      #{prepare}

      # Encrypt existing data
      Grant::Encryption::MigrationHelpers.encrypt_column(
        #{model_class.name},
        :#{attribute}
      )

      # Optional: Remove original column after verification
      #{encrypted_attr.transparent? ? "# (nothing to drop: the value was encrypted in place)" : "# alter_table :#{table_name} do\n      #   drop_column :#{attribute}\n      # end"}
      MIGRATION
    end

    private def self.encrypted_attribute_for(model_class : Grant::Base.class, attribute_name : String) : EncryptedAttribute
      model_class.encrypted_query_attribute(attribute_name) ||
        raise ArgumentError.new("#{model_class} does not have encrypted attribute #{attribute_name}")
    end

    private def self.encrypted_payload?(text : String?) : Bool
      return false if text.nil? || text.empty?
      Cipher.encrypted_payload?(Base64.decode(text))
    rescue Base64::Error
      false
    end

    # Yields the table's rows in primary-key order, *batch_size* at a time, as
    # `{key, first_column_text, second_column_text}` (one query per batch,
    # `WHERE pk > last`). *current* may equal *source*.
    private def self.each_batch(
      model_class : Grant::Base.class,
      source : String,
      current : String,
      batch_size : Int32,
      progress : Bool,
      verb : String,
      & : Array(RawRow) ->
    ) : Nil
      raise ArgumentError.new("batch_size must be positive") unless batch_size > 0

      key_column = model_class.primary_name
      total = model_class.count
      Grant::Log.info { "#{verb} #{total} records..." } if progress

      seen = 0
      last : Grant::Columns::Type = nil
      first = true
      adapter = model_class.adapter
      names = source == current ? [key_column, source] : [key_column, source, current]

      loop do
        relation = model_class.order({key_column => :asc}).limit(batch_size)
        relation = relation.where(key_column, :gt, last) unless first
        assembler = relation.assembler
        sql = assembler.pluck_sql(names)
        arguments = assembler.numbered_parameters

        rows = [] of RawRow
        adapter.open(sql, arguments, model_class.name) do |db|
          db.query(sql, args: adapter.normalize_bind_values(arguments)) do |result|
            result.each do
              key = result.read.as(Grant::Columns::Type)
              plain = result.read(String?)
              other = names.size == 3 ? result.read(String?) : plain
              rows << {key, plain, other}
            end
          end
        end
        break if rows.empty?

        model_class.transaction { yield rows }

        seen += rows.size
        last = rows.last[0]
        first = false
        if progress
          percent = total > 0 ? (seen.to_f / total * 100).round(2) : 100.0
          Grant::Log.info { "Progress: #{seen}/#{total} (#{percent}%)" }
        end
        break if rows.size < batch_size
      end
    end

    # One bound `UPDATE table SET column = ? WHERE pk = ?` per changed row.
    private def self.write_batch(model_class : Grant::Base.class, column : String, changes : Array(Tuple(Grant::Columns::Type, String))) : Nil
      key_column = model_class.primary_name
      changes.each do |key, value|
        model_class.where(key_column, :eq, key).update_all([{column, value.as(Grant::Columns::Type)}])
      end
    end
  end
end
