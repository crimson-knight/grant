module Grant::Encryption
  # Per-fiber encryption settings set by `without_encryption`,
  # `protecting_encrypted_data` and `with_context`. Immutable: entering a block
  # builds a new context and restores the previous one on exit.
  #
  # The context lives on the `Fiber`, never in a class variable, so concurrent
  # requests cannot leak pinned keys or a disabled state into each other. A
  # fiber spawned inside a block starts with the default context.
  struct Context
    getter? encryption_disabled : Bool
    getter? data_protected : Bool
    getter key_set : KeyProvider::KeySet?

    def initialize(@encryption_disabled : Bool = false, @data_protected : Bool = false, @key_set : KeyProvider::KeySet? = nil)
    end

    # Copy with the given fields changed.
    def replace(encryption_disabled : Bool = @encryption_disabled, data_protected : Bool = @data_protected, key_set : KeyProvider::KeySet? = @key_set) : Context
      Context.new(encryption_disabled, data_protected, key_set)
    end
  end

  DEFAULT_CONTEXT = Context.new

  # The context of the current fiber.
  def self.current_context : Context
    Fiber.current.grant_encryption_context || DEFAULT_CONTEXT
  end

  # Whether attributes are encrypted and decrypted in the current fiber.
  def self.encryption_enabled? : Bool
    !current_context.encryption_disabled?
  end

  # Runs the block with encryption switched off for this fiber: encrypted
  # attributes are written as plaintext and read back exactly as stored (raw
  # ciphertext for String attributes; other types cannot be read raw and raise
  # `Grant::Encryption::UnsupportedTypeError`). Use it to inspect or repair
  # stored data. Ignored inside `protecting_encrypted_data`.
  #
  # ```
  # Grant::Encryption.without_encryption { User.find(1).email } # => ciphertext
  # ```
  def self.without_encryption(& : -> T) : T forall T
    context = current_context
    return yield if context.data_protected?
    swap_context(context.replace(encryption_disabled: true)) { yield }
  end

  # Runs the block so that `without_encryption` inside it is ignored and data
  # stays encrypted, even when the block calls code that would switch
  # encryption off. Re-enables encryption for the block.
  def self.protecting_encrypted_data(& : -> T) : T forall T
    swap_context(current_context.replace(encryption_disabled: false, data_protected: true)) { yield }
  end

  # Runs the block with these keys pinned for this fiber instead of the
  # process-wide ones, for a tenant-specific key or a read of data written
  # under an old key. Keys are Base64 strings, as for `Config`. Older keys are
  # not consulted inside the block; the pinned pair is the only one tried.
  #
  # ```
  # Grant::Encryption.with_context(primary_key: tenant_key) { user.save }
  # ```
  def self.with_context(primary_key : String? = nil, deterministic_key : String? = nil, key_derivation_salt : String? = nil, & : -> T) : T forall T
    key_set = KeyProvider::KeySet.new(
      primary_key.try { |key| KeyProvider.decode_key(key) },
      deterministic_key.try { |key| KeyProvider.decode_key(key) },
      key_derivation_salt || KeyProvider.key_derivation_salt
    )
    swap_context(current_context.replace(key_set: key_set)) { yield }
  end

  private def self.swap_context(context : Context, & : -> T) : T forall T
    fiber = Fiber.current
    previous = fiber.grant_encryption_context
    fiber.grant_encryption_context = context
    begin
      yield
    ensure
      fiber.grant_encryption_context = previous
    end
  end

  # Raised when a value cannot be represented in the requested mode, such as
  # reading a non-String attribute raw inside `without_encryption`.
  class UnsupportedTypeError < Grant::ErrorBase
  end
end

class Fiber
  # Fiber-local slot for `Grant::Encryption::Context`.
  # :nodoc:
  property grant_encryption_context : Grant::Encryption::Context?
end
