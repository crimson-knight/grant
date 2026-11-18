# The control for `scripts/check_pcre2_linkage.rb`: a program that uses a
# Regex must show PCRE2, which proves the check can fail.
puts "control".matches?(/\Acon/)
