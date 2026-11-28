# The control for `scripts/check_openssl_linkage.rb`: a program that
# requires the standard library's OpenSSL itself must show OpenSSL, which
# proves the check can fail.
require "openssl"

puts OpenSSL::SSL::Context::Client.new.verify_mode
