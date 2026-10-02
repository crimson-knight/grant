module Grant::Encryption
  # A typed String attribute is not decrypted when its row is loaded. The model
  # keeps the stored ciphertext in the attribute's own column variable, behind
  # `PREFIX`, and the generated reader opens it on first use and keeps the
  # plaintext. Because the marker travels with the variable, `reload`, `dup`,
  # transaction rollback and every reader of the database form see the stored
  # ciphertext, never a half-decrypted value.
  #
  # The prefix starts with a NUL byte, so it cannot be typed by accident; a
  # plaintext that begins with it is refused when assigned.
  module Sealed
    PREFIX = "\u0000grant-sealed:"

    # *stored* (the ciphertext as the column holds it) behind the marker.
    def self.wrap(stored : String) : String
      PREFIX + stored
    end

    def self.sealed?(value : String) : Bool
      value.starts_with?(PREFIX)
    end

    # The ciphertext inside a value made by `wrap`.
    def self.stored(value : String) : String
      value.byte_slice(PREFIX.bytesize)
    end

    # Raises `ArgumentError` for plaintext that would be mistaken for a sealed value.
    def self.guard_plaintext!(attribute_name : String, value : String?) : Nil
      return unless value && sealed?(value)
      raise ArgumentError.new("#{attribute_name} cannot start with the reserved prefix of Grant::Encryption::Sealed")
    end
  end
end
