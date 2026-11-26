require "./error"
require "../../../vendor/beryl"

module Grant::PQ
  # The client certificate a connection presents when the server asks for
  # one (mutual TLS), read from the `sslcert` and `sslkey` connection
  # parameters.
  #
  # ```
  # # postgres://app@db.example.com/app_db?sslmode=verify-full&sslrootcert=/etc/app/server-ca.crt&sslcert=/etc/app/client.crt&sslkey=/etc/app/client.key
  # conninfo = Grant::PQ::ConnInfo.from_conninfo_string(url)
  # if client_certificate = Grant::PQ::ClientCertificate.from(conninfo)
  #   client_certificate.apply_to(tls_context)
  # end
  # ```
  #
  # Grant presents a certificate only when the connection names one. libpq
  # also tries `~/.postgresql/postgresql.crt` and `postgresql.key` when
  # `sslcert` is absent; Grant leaves that out on purpose, so the files an
  # app logs in with are always the ones its connection URL states.
  struct ClientCertificate
    # :nodoc:
    #
    # What the TLS library raises for a PEM file it cannot use.
    alias UnusablePemError = Grant::Beryl::Error

    # The client context connections use: Beryl's.
    alias TLSContext = Grant::Beryl::TLS::Context::Client

    # The line that opens each certificate in a PEM file.
    PEM_CERTIFICATE_HEADER = "-----BEGIN CERTIFICATE-----"

    # The PEM certificate chain, leaf first (`sslcert`).
    getter certificate_path : String
    # The PEM private key of the leaf certificate (`sslkey`).
    getter private_key_path : String

    def initialize(@certificate_path : String, @private_key_path : String)
    end

    # Returns the client certificate *conninfo* names, or nil when it names
    # neither `sslcert` nor `sslkey`. Raises `ConnectionError` when it names
    # only one of them, since a certificate cannot be used without its key.
    def self.from(conninfo : ConnInfo) : ClientCertificate?
      certificate_path = conninfo.sslcert
      private_key_path = conninfo.sslkey
      if certificate_path && private_key_path
        new(certificate_path, private_key_path)
      elsif certificate_path
        raise ConnectionError.new(
          "sslcert=#{certificate_path} was given without sslkey; a client certificate needs both " \
          "(add sslkey=<path to the private key> to the connection URL)")
      elsif private_key_path
        raise ConnectionError.new(
          "sslkey=#{private_key_path} was given without sslcert; a client certificate needs both " \
          "(add sslcert=<path to the certificate> to the connection URL)")
      end
    end

    # Loads the certificate chain and private key into *context*, a
    # `Grant::Beryl::TLS::Context::Client`. The key's permissions are checked
    # first, as libpq checks them (see `refuse_a_private_key_open_to_others`).
    # Raises `ConnectionError` naming the file that could not be used.
    def apply_to(context : TLSContext) : Nil
      refuse_a_private_key_open_to_others
      refuse_a_certificate_file_without_a_certificate
      load_file("sslcert", certificate_path) { context.certificate_chain = certificate_path }
      load_file("sslkey", private_key_path) { context.private_key = private_key_path }
    end

    # Raises `ConnectionError` when the private key file is not a regular
    # file, or when others can read it, with libpq's rule: a key owned by
    # the current user may have permissions u=rw (0600) or less, and a key
    # owned by root may have u=rw,g=r (0640) or less, so a system-managed
    # key can be shared with a group. The current user is the real user id,
    # where libpq compares the effective one; the two differ only in a
    # setuid program. Windows has no such permission bits, and libpq skips
    # the check there too.
    def refuse_a_private_key_open_to_others : Nil
      {% unless flag?(:win32) %}
        file_info = begin
          File.info(private_key_path)
        rescue error : File::Error
          raise ConnectionError.new("sslkey=#{private_key_path} could not be read: #{error.message}", cause: error)
        end

        unless file_info.file?
          raise ConnectionError.new("sslkey=#{private_key_path} is not a regular file")
        end

        permission_bits = file_info.permissions.value
        is_owned_by_root = file_info.owner_id == "0"
        is_open_to_others = if is_owned_by_root
                              permission_bits & 0o137 != 0
                            else
                              permission_bits & 0o077 != 0
                            end
        if is_open_to_others
          raise ConnectionError.new(
            "sslkey=#{private_key_path} has group or world access (permissions 0#{permission_bits.to_s(8)}); " \
            "the private key file must have permissions u=rw (0600) or less if owned by the current user, " \
            "or u=rw,g=r (0640) or less if owned by root (run chmod 600 #{private_key_path})")
        end
      {% end %}
    end

    # Raises `ConnectionError` when the sslcert file holds no PEM
    # certificate (a key or some other file named by mistake), which a TLS
    # library could otherwise read as an empty chain.
    private def refuse_a_certificate_file_without_a_certificate : Nil
      certificate_text = load_file("sslcert", certificate_path) { File.read(certificate_path) }
      unless certificate_text.includes?(PEM_CERTIFICATE_HEADER)
        raise ConnectionError.new("sslcert=#{certificate_path} holds no PEM certificate (#{PEM_CERTIFICATE_HEADER})")
      end
    end

    # Runs the block that reads *path* into the TLS context, and turns a
    # missing file or an unreadable PEM into a `ConnectionError` naming the
    # connection parameter it came from.
    private def load_file(parameter_name : String, path : String, &)
      yield
    rescue error : File::Error
      raise ConnectionError.new("#{parameter_name}=#{path} could not be read: #{error.message}", cause: error)
    rescue error : UnusablePemError
      raise ConnectionError.new("#{parameter_name}=#{path} is not a usable PEM file: #{error.message}", cause: error)
    end
  end
end
