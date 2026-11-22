require "../../spec_helper"
require "../../support/pcre2_only_pattern"

private alias Scanner = Grant::Schema::TableRebuild::Scanner

# {text, name} => whether the text uses the name as an identifier.
private MENTION_EXAMPLES = {
  {"email", "email"}                            => true,
  {"EMAIL", "email"}                            => true,
  {"CHECK (email <> '')", "email"}              => true,
  {"CHECK (\"email\" <> '')", "email"}          => true,
  {"CHECK (`email` <> '')", "email"}            => true,
  {"CHECK ([email] <> '')", "email"}            => true,
  {"UNIQUE (email, name)", "name"}              => true,
  {"UNIQUE (email,name)", "name"}               => true,
  {"FOREIGN KEY (author_id) REFERENCES a", "a"} => true,
  {"email\n", "email"}                          => true,
  {"lower(email)", "email"}                     => true,
  {"CHECK (email_address <> '')", "email"}      => false,
  {"CHECK (work_email <> '')", "email"}         => false,
  {"CHECK (email2 <> '')", "email"}             => false,
  {"CHECK (\"email\"x <> '')", "email"}         => true,
  {"CHECK (x\"email\" <> '')", "email"}         => true,
  {"CHECK (émail <> '')", "mail"}               => false,
  {"", "email"}                                 => false,
  {"CHECK (a.b > 0)", "a.b"}                    => true,
  {"CHECK (axb > 0)", "a.b"}                    => false,
  {"price > 0 AND price < 10", "price"}         => true,
  {"\"price", "price"}                          => true,
  {"price\"", "price"}                          => true,
}

describe Grant::Schema::TableRebuild::Scanner do
  it "finds a name used as an identifier and passes over one inside a longer word" do
    MENTION_EXAMPLES.each do |(text, name), mentioned|
      Scanner.mentions?(text, name).should eq(mentioned), "for #{name.inspect} in #{text.inspect}"
    end
  end

  it "answers as the lookaround pattern of Grant 0.25.0 answered" do
    list_of_checked_examples = MENTION_EXAMPLES.compact_map do |(text, name), mentioned|
      pattern_of_grant_0_25_0 = PCRE2OnlyPattern.compile?(%q((?<![\w])["`\[]?) + Regex.escape(name) + %q(["`\]]?(?![\w])), Regex::Options::IGNORE_CASE)
      next unless pattern_of_grant_0_25_0
      text.matches?(pattern_of_grant_0_25_0).should eq(mentioned), "for #{name.inspect} in #{text.inspect}"
      text
    end
    pending!("this Regex engine does not run lookaround; build with -Duse_pcre2") if list_of_checked_examples.empty?
  end
end
