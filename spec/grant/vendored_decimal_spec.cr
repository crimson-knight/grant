require "../spec_helper"
require "digest/sha256"
require "json"

private struct VendoredDecimalFile
  include JSON::Serializable

  getter path : String = ""
  getter sha256 : String = ""
end

private struct VendoredDecimalManifest
  include JSON::Serializable

  getter source : String = ""
  getter commit : String = ""
  getter component : String = ""
  getter namespace : String = ""
  getter list_of_files : Array(VendoredDecimalFile) = [] of VendoredDecimalFile
end

private DECIMAL_VENDOR_ROOT = Path[__DIR__].parent.parent / "src" / "grant" / "vendor" / "decimal"

# Mica's decimal component (Grant::Decimal128, Grant::Money) is pinned in its
# own directory beside the deflate copy: scripts/vendor_into.rb replaces the
# whole `mica` tree of its destination, so each component keeps its own.
describe "the vendored copy of Mica's decimal component" do
  manifest = VendoredDecimalManifest.from_json(File.read(DECIMAL_VENDOR_ROOT / "MICA_VENDORED.json"))

  it "names its source, a full commit, the decimal component and the Grant::Mica namespace" do
    manifest.source.should eq("https://github.com/amberframework/mica")
    manifest.commit.size.should eq(40)
    manifest.commit.each_char.all? { |character| character.ascii_number? || ('a'..'f').includes?(character) }.should be_true
    manifest.component.should eq("decimal")
    manifest.namespace.should eq("Grant::Mica")
    manifest.list_of_files.should_not be_empty
  end

  it "holds every pinned file with its pinned sha256" do
    manifest.list_of_files.each do |vendored_file|
      observed_sha256 = Digest::SHA256.hexdigest(File.read(DECIMAL_VENDOR_ROOT / vendored_file.path))
      fail "src/grant/vendor/decimal/#{vendored_file.path} does not match its pin" unless observed_sha256 == vendored_file.sha256
    end
  end

  it "holds no file without a pin" do
    list_of_present = Dir.glob((DECIMAL_VENDOR_ROOT / "mica" / "**" / "*.cr").to_s).map { |path| Path[path].relative_to(DECIMAL_VENDOR_ROOT).to_s }
    (list_of_present - manifest.list_of_files.map(&.path)).should be_empty
  end

  it "exposes the vendored types as Grant::Decimal128, Grant::Money and Grant::Currency" do
    Grant::Decimal128.parse("12.30").to_s.should eq "12.30"
    Grant::Money.new(Grant::Decimal128.parse("100.00"), "USD").split(3).map(&.amount.to_s).should eq ["33.34", "33.33", "33.33"]
    Grant::Currency.find("JPY").minor_units.should eq 0
  end
end
