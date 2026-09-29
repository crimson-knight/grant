require "./attribute_models"

describe "inspect and filter_attributes" do
  before_all do
    Grant::Encryption.configure do |config|
      config.primary_key = Base64.strict_encode("test_primary_key_32_bytes_long!!".to_slice)
      config.deterministic_key = Base64.strict_encode("test_determ_key_32_bytes_long!!!".to_slice)
      config.key_derivation_salt = Base64.strict_encode("test_salt_key_32_bytes_long!!!!!".to_slice)
    end
  end

  after_each { Grant.settings.filter_attributes = [] of String | Regex }

  it "prints only the columns, readably" do
    post = AttrPost.new(title: "Hello", views: 3)
    text = post.inspect
    text.should start_with("#<AttrPost id: nil, title: \"Hello\", views: 3, published: nil")
    text.should_not contain("original_attributes")
    text.should_not contain("changed_attributes")
    text.should end_with(">")
  end

  it "truncates long strings" do
    AttrPost.new(title: "x" * 80).inspect.should contain("#{"x" * 50}...")
  end

  it "filters encrypted columns by default and keeps nil visible" do
    account = AttrAccount.new(email: "a@b.c")
    account.inspect.should contain("email: \"a@b.c\"")
    account.inspect.should contain("ssn_encrypted: nil")

    account.ssn = "123-45-6789"
    text = account.inspect
    text.should contain("ssn_encrypted: [FILTERED]")
    text.should_not contain("123-45-6789")
  end

  it "filters global names, patterns and per-model names" do
    account = AttrAccount.new(email: "a@b.c", password_digest: "secret-digest", api_token: "tok")
    account.inspect.should contain("password_digest: \"secret-digest\"")
    account.inspect.should contain("api_token: [FILTERED]")

    Grant.settings.filter_attributes = ["password"] of String | Regex
    account.inspect.should contain("password_digest: [FILTERED]")
    account.inspect.should_not contain("secret-digest")

    Grant.settings.filter_attributes = [/\Aemail\z/] of String | Regex
    account.inspect.should contain("email: [FILTERED]")
    account.inspect.should contain("api_token: [FILTERED]")
  end

  it "does not leak filtered values through to_s of a collection" do
    Grant.settings.filter_attributes = ["password"] of String | Regex
    account = AttrAccount.new(password_digest: "hunter2")
    [account].inspect.should_not contain("hunter2")
  end
end
