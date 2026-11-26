require "../vendor/beryl/certificates/trust_store"
require "../vendor/beryl/crypto"

module Grant::Schema
  # Writes the trust anchors of a Beryl `TrustStore` to a PEM file, for
  # `pg_dump` and `psql`: libpq reads trust anchors from a file only, so a
  # store Beryl builds in memory (on macOS, `TrustStore.system` joins the
  # pinned Mozilla roots to `/etc/ssl/cert.pem`) reaches libpq this way.
  #
  # The file holds each certificate of the store once, in the store's order,
  # as Beryl encodes it (`Certificate#to_pem`), so libpq trusts exactly the
  # anchors Grant's driver trusts. It is named by the sha256 of its content,
  # in a directory only this user can read, written to a temporary file and
  # renamed into place, readable by this user only, and reused while its
  # content still matches its name.
  #
  # ```
  # store = Grant::Beryl::Certificates::TrustStore.system
  # Grant::Schema::WriteTrustAnchorsForCommandLineTools.new(store).perform
  # # => "/Users/me/Library/Caches/grant/trust-anchors-<sha256>.pem"
  # ```
  # :nodoc:
  class WriteTrustAnchorsForCommandLineTools
    FILE_NAME_PREFIX = "trust-anchors-"

    getter directory : ::String

    def initialize(@trust_store : Grant::Beryl::Certificates::TrustStore, @directory : ::String = self.class.cache_directory)
    end

    # This user's cache directory for Grant: `~/Library/Caches/grant` on
    # macOS, else `$XDG_CACHE_HOME/grant` or `~/.cache/grant`.
    def self.cache_directory : ::String
      {% if flag?(:darwin) %}
        File.join(Path.home.to_s, "Library", "Caches", "grant")
      {% else %}
        base = ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home.to_s, ".cache")
        File.join(base, "grant")
      {% end %}
    end

    # The path of the file holding the store's anchors, written when no
    # matching file is there yet.
    def perform : ::String
      pem = String.build do |io|
        @trust_store.list_of_certificates.each { |certificate| io << certificate.to_pem }
      end
      checksum = Grant::Beryl::Crypto::V1::SHA256.hexdigest(pem)
      path = File.join(@directory, "#{FILE_NAME_PREFIX}#{checksum}.pem")
      return path if file_matches?(path, checksum)

      Dir.mkdir_p(@directory, 0o700)
      temporary_file = File.tempfile(FILE_NAME_PREFIX, ".pem", dir: @directory) do |file|
        file.print(pem)
      end
      File.rename(temporary_file.path, path)
      path
    rescue error : File::Error
      raise StructureToolError.new("could not write the trust anchors for pg_dump and psql to #{@directory}: #{error.message}")
    end

    private def file_matches?(path : ::String, checksum : ::String) : Bool
      existing_file = File.info?(path, follow_symlinks: false)
      return false unless existing_file && existing_file.type.file?

      Grant::Beryl::Crypto::V1::SHA256.hexdigest(File.read(path)) == checksum
    end
  end
end
