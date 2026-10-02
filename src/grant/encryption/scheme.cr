module Grant::Encryption
  # An older way an attribute was encrypted, kept so its rows stay readable
  # while new writes use the current scheme (`encrypts ssn, previous: [...]`).
  #
  # A scheme names the key (and optionally the salt) the old data was written
  # under. Without a key it reuses the process-wide keys, which is what you want
  # when only `deterministic:` changed. Schemes are tried newest first, after the
  # current keys and any `Config.primary_keys` history.
  struct Scheme
    getter deterministic : Bool
    getter primary_key : Bytes?
    getter deterministic_key : Bytes?
    getter salt : String?

    def initialize(@deterministic : Bool = false, @primary_key : Bytes? = nil, @deterministic_key : Bytes? = nil, @salt : String? = nil)
    end

    # Builds a scheme from Base64 text. *key* is the deterministic key when
    # *deterministic* is true and the primary key otherwise.
    def self.build(deterministic : Bool = false, key : String? = nil, salt : String? = nil) : Scheme
      decoded = key.try { |encoded| KeyProvider.decode_key(encoded) }
      new(deterministic, deterministic ? nil : decoded, deterministic ? decoded : nil, salt)
    end

    # Whether the scheme carries anything the current keys do not already cover.
    def overrides_keys? : Bool
      !@primary_key.nil? || !@deterministic_key.nil? || !@salt.nil?
    end
  end
end
