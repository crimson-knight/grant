require "../../spec_helper"

# Values written by Grant 0.24.0, whose cipher, key derivation and
# signatures ran on OpenSSL. They were captured before the move to Beryl and
# must be read, byte for byte, for as long as such values exist in a
# database.
private module ValuesWrittenOnOpenSSL
  KEY       = Bytes.new(32) { |index| (index * 7 + 3).to_u8 }
  PLAINTEXT = "123-45-6789, a value longer than one cipher block"

  VERSION_1_RANDOM        = "AeuZ31ZHwLRSaQfCdySnqUzkrbcCiihbnAG+ujiRmrF5F4beURzcFmvy62vig1FglrJbpAEOLK/acNATpourexRLR5JMB2TUKYcq+c9mbGt18jbo6fatytd/wbY5gU390NQs7lqdPK+xOpb2pijrsvM="
  VERSION_1_DETERMINISTIC = "gZ/D4zN1Xt1SSzp1tgS8N6Ozu9xJq6gii+zMokLaZcsVsMekne1lzzHwGNhYBOCBZxIhQPsq48nWb1l3mtofo0r58jfJZLRt2UeIROudISws3y7dbFih1eAI8uiQ86ep4ATRu9QAYc7sbkY5YIcblfA="
  VERSION_1_SHORT         = "Acgggi9vfz+zNnxSp0oPDkReOe5rGDZxQEMZ4m4mTC5oSueS932THT59SKQcgfGg1CxIUa6do/R6VPrfTpAdcHs="

  PRIMARY_KEY       = Bytes.new(32) { |index| (index + 100).to_u8 }
  DETERMINISTIC_KEY = Bytes.new(32) { |index| (200 - index).to_u8 }
  SALT              = "fixture-salt"

  DERIVED_KEY_FOR_USER_SSN            = "3a057dae29865a9659517cfcb170f7edb4514c30c894d33de5128540dd65fbac"
  DERIVED_KEY_FOR_USER_EMAIL          = "8ed57c8cb9447b0dfa08770d8e3ff4b69c7ef5ae60b44302dca9400bd2683eed"
  DERIVED_KEY_FOR_BILLING_CARD_NUMBER = "60737c052897458cf1e336513403f083174dc1a35d04222190f56060f43f4bba"

  HMAC_SHA256_OF_SELECTOR_STAMP = "1763004c072d5c867ad1baa0f303aeca69810cb9834f249086cbd9a26a3340c3"
  MD5_OF_LOCK_NAME              = "1c49afd0d95c0220d98337315b9c9a99"
  SCRAM_SALTED_PASSWORD         = "c4a49510323ab4f952cac1fa99441939e78ea74d6be81ddf7096e87513dc615d" # secret-scan-gate:allow (derived from the RFC 7677 example password)
end

describe Grant::Encryption::Cipher do
  describe "format version 2" do
    it "writes the header byte, a 24-byte nonce, the ciphertext and a 16-byte tag" do
      sealed = Grant::Encryption::Cipher.encrypt("hello", ValuesWrittenOnOpenSSL::KEY)

      sealed[0].should eq(2_u8)
      sealed.size.should eq(1 + 24 + 5 + 16)
      Grant::Encryption::Cipher.payload_version(sealed).should eq(2_u8)
      Grant::Encryption::Cipher.encrypted_payload?(sealed).should be_true
      Grant::Encryption::Cipher.deterministic_payload?(sealed).should be_false
      Grant::Encryption::Cipher.decrypt(sealed, ValuesWrittenOnOpenSSL::KEY).should eq("hello")
    end

    it "is XChaCha20-Poly1305 under an HKDF-SHA256 key, with the header byte authenticated" do
      sealed = Grant::Encryption::Cipher.encrypt("hello", ValuesWrittenOnOpenSSL::KEY)
      key = Grant::Beryl::Crypto::V1::HKDF(Grant::Beryl::Crypto::V1::SHA256).derive_key(
        ValuesWrittenOnOpenSSL::KEY, info: "grant cipher v2 encryption", bytesize: 32
      )
      opened = Grant::Beryl::Crypto::V1::XChaCha20Poly1305.new(key).decrypt(
        sealed[25, sealed.size - 25], nonce: sealed[1, 24], associated_data: sealed[0, 1]
      )
      opened.should eq("hello".to_slice)
    end

    it "draws a new nonce for every value" do
      first = Grant::Encryption::Cipher.encrypt("same", ValuesWrittenOnOpenSSL::KEY)
      second = Grant::Encryption::Cipher.encrypt("same", ValuesWrittenOnOpenSSL::KEY)
      first.should_not eq(second)
    end

    it "gives equal bytes for equal plaintext in deterministic mode, and sets the flag" do
      first = Grant::Encryption::Cipher.encrypt("same", ValuesWrittenOnOpenSSL::KEY, true)
      second = Grant::Encryption::Cipher.encrypt("same", ValuesWrittenOnOpenSSL::KEY, true)
      other = Grant::Encryption::Cipher.encrypt("other", ValuesWrittenOnOpenSSL::KEY, true)

      first.should eq(second)
      first.should_not eq(other)
      first[0].should eq(0x82_u8)
      Grant::Encryption::Cipher.deterministic_payload?(first).should be_true
      Grant::Encryption::Cipher.decrypt(first, ValuesWrittenOnOpenSSL::KEY).should eq("same")
    end

    it "returns nil from decrypt? and raises from decrypt for a value with any byte changed" do
      sealed = Grant::Encryption::Cipher.encrypt("tamper with me", ValuesWrittenOnOpenSSL::KEY)
      (1...sealed.size).each do |position|
        altered = sealed.dup
        altered[position] ^= 0x01_u8
        Grant::Encryption::Cipher.decrypt?(altered, ValuesWrittenOnOpenSSL::KEY).should be_nil
      end

      with_the_flag_set = sealed.dup
      with_the_flag_set[0] |= 0x80_u8
      Grant::Encryption::Cipher.decrypt?(with_the_flag_set, ValuesWrittenOnOpenSSL::KEY).should be_nil
      expect_raises(Grant::Encryption::Cipher::DecryptionError) do
        Grant::Encryption::Cipher.decrypt(with_the_flag_set, ValuesWrittenOnOpenSSL::KEY)
      end
    end

    it "returns nil from decrypt? under another key" do
      sealed = Grant::Encryption::Cipher.encrypt("hello", ValuesWrittenOnOpenSSL::KEY)
      Grant::Encryption::Cipher.decrypt?(sealed, Bytes.new(32, 1_u8)).should be_nil
    end

    it "raises DecryptionError for a value too short to hold a nonce and a tag" do
      expect_raises(Grant::Encryption::Cipher::DecryptionError, "too short") do
        Grant::Encryption::Cipher.decrypt?(Bytes[2, 0, 0], ValuesWrittenOnOpenSSL::KEY)
      end
    end

    it "keeps an empty value as empty bytes" do
      Grant::Encryption::Cipher.encrypt("", ValuesWrittenOnOpenSSL::KEY).should eq(Bytes.empty)
      Grant::Encryption::Cipher.decrypt(Bytes.empty, ValuesWrittenOnOpenSSL::KEY).should eq("")
    end
  end

  describe "format version 1, written on OpenSSL" do
    it "reads a value with a random initialization vector" do
      stored = Base64.decode(ValuesWrittenOnOpenSSL::VERSION_1_RANDOM)
      Grant::Encryption::Cipher.payload_version(stored).should eq(1_u8)
      Grant::Encryption::Cipher.encrypted_payload?(stored).should be_true
      Grant::Encryption::Cipher.decrypt(stored, ValuesWrittenOnOpenSSL::KEY).should eq(ValuesWrittenOnOpenSSL::PLAINTEXT)
    end

    it "reads a one-character value" do
      stored = Base64.decode(ValuesWrittenOnOpenSSL::VERSION_1_SHORT)
      Grant::Encryption::Cipher.decrypt(stored, ValuesWrittenOnOpenSSL::KEY).should eq("a")
    end

    it "reads a deterministic value" do
      stored = Base64.decode(ValuesWrittenOnOpenSSL::VERSION_1_DETERMINISTIC)
      Grant::Encryption::Cipher.deterministic_payload?(stored).should be_true
      Grant::Encryption::Cipher.decrypt(stored, ValuesWrittenOnOpenSSL::KEY).should eq(ValuesWrittenOnOpenSSL::PLAINTEXT)
    end

    it "reproduces a deterministic value byte for byte, so a lookup finds the stored row" do
      reproduced = Grant::Encryption::Cipher.encrypt_in_version_1(ValuesWrittenOnOpenSSL::PLAINTEXT, ValuesWrittenOnOpenSSL::KEY, true)
      Base64.strict_encode(reproduced).should eq(ValuesWrittenOnOpenSSL::VERSION_1_DETERMINISTIC)
    end

    it "returns nil from decrypt? for a value with any byte changed, and under another key" do
      stored = Base64.decode(ValuesWrittenOnOpenSSL::VERSION_1_RANDOM)
      (1...stored.size).each do |position|
        altered = stored.dup
        altered[position] ^= 0x01_u8
        Grant::Encryption::Cipher.decrypt?(altered, ValuesWrittenOnOpenSSL::KEY).should be_nil
      end
      Grant::Encryption::Cipher.decrypt?(stored, Bytes.new(32, 1_u8)).should be_nil
    end
  end
end

describe Grant::Encryption::KeyProvider do
  it "derives the attribute keys Grant 0.24.0 derived (HKDF-SHA256)" do
    {
      {"User", "ssn", false}             => ValuesWrittenOnOpenSSL::DERIVED_KEY_FOR_USER_SSN,
      {"User", "email", true}            => ValuesWrittenOnOpenSSL::DERIVED_KEY_FOR_USER_EMAIL,
      {"Billing::Card", "number", false} => ValuesWrittenOnOpenSSL::DERIVED_KEY_FOR_BILLING_CARD_NUMBER,
    }.each do |attribute, expected_key|
      derived_key = Grant::Encryption::KeyProvider.derive_key_with_keys(
        attribute[0], attribute[1], attribute[2],
        ValuesWrittenOnOpenSSL::PRIMARY_KEY, ValuesWrittenOnOpenSSL::DETERMINISTIC_KEY, ValuesWrittenOnOpenSSL::SALT
      )
      derived_key.hexstring.should eq(expected_key)
    end
  end
end

describe "Beryl primitives Grant signs, hashes and authenticates with" do
  it "computes the HMAC-SHA256 OpenSSL computed" do
    tag = Grant::Beryl::Crypto::V1::HMAC(Grant::Beryl::Crypto::V1::SHA256).authenticate("1763830000", key: "selector-secret")
    tag.hexstring.should eq(ValuesWrittenOnOpenSSL::HMAC_SHA256_OF_SELECTOR_STAMP)
  end

  it "computes the MD5 OpenSSL computed, through digest, hexdigest and the block form" do
    text = "grant advisory lock: orders/42"
    Grant::Beryl::Crypto::Compatibility::MD5.hexdigest(text).should eq(ValuesWrittenOnOpenSSL::MD5_OF_LOCK_NAME)
    Grant::Beryl::Crypto::Compatibility::MD5.digest(text).hexstring.should eq(ValuesWrittenOnOpenSSL::MD5_OF_LOCK_NAME)
    in_two_parts = Grant::Beryl::Crypto::Compatibility::MD5.hexdigest do |context|
      context.update("grant advisory lock: ")
      context.update("orders/42")
    end
    in_two_parts.should eq(ValuesWrittenOnOpenSSL::MD5_OF_LOCK_NAME)
  end

  it "computes the SCRAM-SHA-256 salted password OpenSSL computed (PBKDF2, 4,096 iterations)" do
    salted_password = Grant::Beryl::Crypto::Compatibility::PBKDF2(Grant::Beryl::Crypto::V1::SHA256).derive_key(
      "pencil", salt: Base64.decode("W22ZaJ0SNY7soEsUEjb6gQ=="), iteration_count: 4096, bytesize: 32
    )
    salted_password.hexstring.should eq(ValuesWrittenOnOpenSSL::SCRAM_SALTED_PASSWORD)
  end
end
