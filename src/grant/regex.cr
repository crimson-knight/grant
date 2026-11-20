# Regex support for Grant, opt-in. Grant's default path (models, querying,
# saving, validating, logging and the adapters) uses hand-written text checks,
# so an app links no PCRE2 unless it asks for a regular expression. Require
# this file after `grant` (and before the models that use it) to enable:
#
# - `validates_format_of` (and `validates ... format: /.../`)
# - Regex entries in `filter_attributes` and `Grant.settings.filter_attributes`
# - the `REGEXP` SQL operator on SQLite connections
# - `Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX` and `URL_REGEX`
#
# ```
# require "grant"
# require "grant/adapter/sqlite"
# require "grant/regex"
# ```
require "../grant"
require "./regex/*"
