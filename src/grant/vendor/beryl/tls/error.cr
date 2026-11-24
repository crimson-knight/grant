require "../error"

module Grant::Beryl::TLS
  # The base of every TLS error. `alert_description` is the alert the
  # connection sends (or, for `PeerAlert`, received) when it fails.
  class Error < Grant::Beryl::Error
    getter alert_description : AlertDescription

    def initialize(message : String, @alert_description : AlertDescription = AlertDescription::InternalError)
      super(message)
    end
  end

  # The peer sent a fatal alert, or a warning other than close_notify that
  # TLS 1.3 treats as fatal (RFC 9846 §6.2).
  class PeerAlert < Error
  end

  # An alert that arrived in plaintext while the connection already had
  # keys. Nothing authenticates it, so it may come from anyone on the path
  # rather than the peer; it still ends the handshake, as any alert there
  # would.
  class UnauthenticatedAlert < PeerAlert
  end

  # The handshake did not finish before its deadline.
  class HandshakeTimeout < Error
  end

  # The connection is closed, or was closed by the peer's close_notify,
  # and cannot carry more data in that direction.
  class ConnectionClosed < Error
  end

  # The peer's certificate chain did not verify.
  class CertificateRejected < Error
  end
end
