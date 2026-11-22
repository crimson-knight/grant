# The three substitutions that put `::` in front of every type name in the
# text of a type, so `Array(Tuple(Connection, Int64))` written inside `Grant`
# names `::Connection` and not `Grant::Connection`. A named-tuple key
# (`Foo:`) is left as written.
#
# `Grant::Query::Builder` runs them in a macro, where the compiler's own regex
# engine does the work. They use no lookaround and no possessive quantifier, so
# a compiler whose engine is Mica runs them as PCRE2 does. In order:
#
# 1. `NAMED_TUPLE_KEY` puts a mark (U+0001) in front of each capitalized name that
#    one colon follows.
# 2. `UNROOTED_NAME` roots each capitalized name that starts a word and has no
#    colon, quote or mark in front of it.
# 3. `KEY_MARK_PATTERN` takes the marks out again.
module Grant::Query::TypeNameRooting
  NAMED_TUPLE_KEY        = /([A-Z]\w*):([^:]|$)/
  MARKED_NAMED_TUPLE_KEY = "\u0001\\1:\\2"
  UNROOTED_NAME          = /(^|[^:\w"\x01])([A-Z]\w*)/
  ROOTED_NAME            = "\\1::\\2"
  KEY_MARK_PATTERN       = /\x01/
end
