# The Crystal compiler a spec shells out to: crystal-alpha when it is on PATH
# (the house toolchain), otherwise the stock crystal CI installs.
def spec_crystal_compiler : String
  Process.find_executable("crystal-alpha") || Process.find_executable("crystal") || raise "No Crystal compiler on PATH"
end
