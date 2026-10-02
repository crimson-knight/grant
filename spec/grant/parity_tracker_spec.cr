require "../spec_helper"
require "../../scripts/parity_generator"

describe "generated Grant parity tracker" do
  it "matches parity.json without rewriting the generated files" do
    root = Dir.current
    source = GrantParity::SourceDocument.from_json(File.read(File.join(root, "docs", "parity", "parity.json")))
    rendered = GrantParity::Generator.render(source, Grant::VERSION, root)

    File.read(File.join(root, "docs", "PARITY.md")).should eq(rendered.markdown)
    File.read(File.join(root, "src", "grant", "parity.cr")).should eq(rendered.crystal)
    File.read(File.join(root, "docs", "parity", "#{Grant::VERSION}.md")).should eq(rendered.markdown)
  end
end
