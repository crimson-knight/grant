require "../../spec_helper"

private alias TrustStore = Grant::Beryl::Certificates::TrustStore

private def with_ssl_cert_file(path : String?, &)
  previous = ENV["SSL_CERT_FILE"]?
  path ? (ENV["SSL_CERT_FILE"] = path) : ENV.delete("SSL_CERT_FILE")
  begin
    yield
  ensure
    previous ? (ENV["SSL_CERT_FILE"] = previous) : ENV.delete("SSL_CERT_FILE")
  end
end

private def with_cache_directory(&)
  directory = File.tempname("grant-trust-anchor-cache")
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

# A bundle of three Mozilla roots, the first one twice, as a system bundle
# can list a root twice.
private def with_three_root_bundle(&)
  list_of_roots = TrustStore.mozilla.list_of_certificates.first(3)
  bundle = File.tempname("grant-ssl-cert-file", ".pem")
  File.write(bundle, (list_of_roots + [list_of_roots.first]).join(&.to_pem))
  begin
    yield bundle, list_of_roots
  ensure
    File.delete?(bundle)
  end
end

private def anchors_in(path : String) : Array(Grant::Beryl::Certificates::Certificate)
  TrustStore.from_pem(File.read(path)).list_of_certificates
end

describe Grant::Schema::WriteTrustAnchorsForCommandLineTools do
  it "writes exactly TrustStore.system's anchors when SSL_CERT_FILE names a bundle" do
    with_three_root_bundle do |bundle, list_of_roots|
      with_ssl_cert_file(bundle) do
        with_cache_directory do |directory|
          system_store = TrustStore.system
          path = Grant::Schema::WriteTrustAnchorsForCommandLineTools.new(system_store, directory).perform

          anchors_in(path).should eq(system_store.list_of_certificates)
          anchors_in(path).should eq(list_of_roots)
          File.read(path).should eq(list_of_roots.join(&.to_pem))
        end
      end
    end
  end

  it "writes exactly TrustStore.system's anchors when SSL_CERT_FILE is not set" do
    with_ssl_cert_file(nil) do
      with_cache_directory do |directory|
        system_store = TrustStore.system
        path = Grant::Schema::WriteTrustAnchorsForCommandLineTools.new(system_store, directory).perform

        anchors_in(path).should eq(system_store.list_of_certificates)
        {% if flag?(:darwin) %}
          # /etc/ssl/cert.pem joined with Beryl's pinned Mozilla roots.
          list_of_written_anchors = anchors_in(path)
          TrustStore.mozilla.list_of_certificates.each do |root|
            list_of_written_anchors.should contain(root)
          end
          TrustStore.from_pem(File.read("/etc/ssl/cert.pem")).list_of_certificates.each do |root|
            list_of_written_anchors.should contain(root)
          end
        {% end %}
      end
    end
  end

  it "names the file by its content and reuses it while the content matches" do
    with_three_root_bundle do |bundle, _|
      with_ssl_cert_file(bundle) do
        with_cache_directory do |directory|
          writer = Grant::Schema::WriteTrustAnchorsForCommandLineTools.new(TrustStore.system, directory)
          path = writer.perform
          content = File.read(path)
          File.basename(path).should eq("trust-anchors-#{Grant::Beryl::Crypto::V1::SHA256.hexdigest(content)}.pem")

          File.touch(path, Time.utc(2020, 1, 1))
          writer.perform.should eq(path)
          File.info(path).modification_time.should eq(Time.utc(2020, 1, 1))

          File.write(path, "tampered")
          writer.perform.should eq(path)
          File.read(path).should eq(content)
          Dir.children(directory).should eq([File.basename(path)])
        end
      end
    end
  end

  {% unless flag?(:win32) %}
    it "keeps the directory and the file readable by this user only" do
      with_three_root_bundle do |bundle, _|
        with_ssl_cert_file(bundle) do
          with_cache_directory do |directory|
            path = Grant::Schema::WriteTrustAnchorsForCommandLineTools.new(TrustStore.system, directory).perform

            File.info(directory).permissions.value.should eq(0o700)
            File.info(path).permissions.value.should eq(0o600)
          end
        end
      end
    end
  {% end %}

  it "raises a StructureToolError when the directory cannot be written" do
    with_three_root_bundle do |bundle, _|
      blocking_file = File.tempname("grant-not-a-directory")
      File.write(blocking_file, "")
      begin
        writer = Grant::Schema::WriteTrustAnchorsForCommandLineTools.new(TrustStore.from_pem(File.read(bundle)), File.join(blocking_file, "grant"))
        expect_raises(Grant::Schema::StructureToolError, /could not write the trust anchors/) do
          writer.perform
        end
      ensure
        File.delete?(blocking_file)
      end
    end
  end
end
