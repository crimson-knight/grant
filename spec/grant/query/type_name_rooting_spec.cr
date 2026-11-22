require "spec"
require "../../../src/grant/query/type_name_rooting"
require "../../support/pcre2_only_pattern"

private alias Rooting = Grant::Query::TypeNameRooting

# The substitutions `Grant::Query::Builder` runs in its macro, run here on
# the program's own `Regex` engine.
private def root_with_shipped_patterns(type_name : String) : String
  type_name
    .gsub(Rooting::NAMED_TUPLE_KEY, Rooting::MARKED_NAMED_TUPLE_KEY)
    .gsub(Rooting::UNROOTED_NAME, Rooting::ROOTED_NAME)
    .gsub(Rooting::KEY_MARK_PATTERN, "")
end

# What Grant 0.25.0 ran: one pattern with lookbehind, a possessive
# quantifier and a nested lookahead.
private PATTERN_OF_GRANT_0_25_0 = PCRE2OnlyPattern.compile?(%q((?<![:\w"])([A-Z]\w*+)(?!:(?!:))))

private EXPECTED_ROOTED_NAMES = {
  "Int64"                                           => "::Int64",
  "Array(Int64)"                                    => "::Array(::Int64)",
  "Array(Connection)"                               => "::Array(::Connection)",
  "Array(Tuple(Connection, Int64))"                 => "::Array(::Tuple(::Connection, ::Int64))",
  "Array(Range(Int32, Int32))"                      => "::Array(::Range(::Int32, ::Int32))",
  "Array(Grant::Base)"                              => "::Array(::Grant::Base)",
  "Array(::Connection)"                             => "::Array(::Connection)",
  "Array(Int64 | String | Nil)"                     => "::Array(::Int64 | ::String | ::Nil)",
  "Array(NamedTuple(id: Int64, owner: Connection))" => "::Array(::NamedTuple(id: ::Int64, owner: ::Connection))",
  "Array(NamedTuple(Owner: Connection))"            => "::Array(::NamedTuple(Owner: ::Connection))",
  "NamedTuple(Owner: Connection, Size: Int32)"      => "::NamedTuple(Owner: ::Connection, Size: ::Int32)",
  "NamedTuple(\"Owner name\": Connection)"          => "::NamedTuple(\"Owner name\": ::Connection)",
  "Array(Foo::Bar::Baz)"                            => "::Array(::Foo::Bar::Baz)",
  "Array(fooBar)"                                   => "::Array(fooBar)",
  "Hash(String, Array(Proc(Int32, Nil)))"           => "::Hash(::String, ::Array(::Proc(::Int32, ::Nil)))",
  "Array(UInt8)*"                                   => "::Array(::UInt8)*",
  "Owner:"                                          => "Owner:",
  "Owner::"                                         => "::Owner::",
  ""                                                => "",
}

describe Grant::Query::TypeNameRooting do
  it "roots every type name and leaves named-tuple keys as written" do
    EXPECTED_ROOTED_NAMES.each do |type_name, rooted_name|
      root_with_shipped_patterns(type_name).should eq(rooted_name), "for #{type_name}"
    end
  end

  it "leaves no mark in the text it returns" do
    EXPECTED_ROOTED_NAMES.each_key do |type_name|
      root_with_shipped_patterns(type_name).should_not contain('\u0001')
    end
  end

  if pattern_of_grant_0_25_0 = PATTERN_OF_GRANT_0_25_0
    it "gives the text the lookaround pattern of Grant 0.25.0 gave" do
      EXPECTED_ROOTED_NAMES.each do |type_name, rooted_name|
        type_name.gsub(pattern_of_grant_0_25_0, "::\\1").should eq(rooted_name), "for #{type_name}"
      end
    end
  else
    pending "gives the text the lookaround pattern of Grant 0.25.0 gave (this Regex engine does not run lookaround; build with -Duse_pcre2)"
  end
end
