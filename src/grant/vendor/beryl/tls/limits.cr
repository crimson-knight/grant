module Grant::Beryl::TLS
  # The bounds a connection puts on what its peer sends (plan §4, "Limits
  # on untrusted input"). The defaults are the plan's; an application may
  # tighten them through `Context::Client#limits=` or
  # `Context::Server#limits=`.
  struct Limits
    # The largest handshake message read, header excluded.
    getter largest_handshake_message_bytesize : Int32
    # The largest Certificate message's certificate list.
    getter largest_certificate_chain_bytesize : Int32
    # The most certificates in one Certificate message.
    getter largest_certificate_count : Int32
    # The most records in a row that carry no content.
    getter largest_consecutive_empty_record_count : Int32
    # The most warning alerts in a row (closes the "SSL Death Alert" class,
    # CVE-2016-8610).
    getter largest_consecutive_warning_alert_count : Int32
    # The most KeyUpdate messages read in one minute.
    getter largest_key_update_count_per_minute : Int32
    # The most bytes of refused 0-RTT records a server skips (RFC 9846
    # §4.2.10).
    getter largest_skipped_early_data_bytesize : Int32
    # How long a handshake may take before the socket is closed.
    getter handshake_timeout : Time::Span

    def initialize(
      *,
      @largest_handshake_message_bytesize : Int32 = 65_536,
      @largest_certificate_chain_bytesize : Int32 = 65_536,
      @largest_certificate_count : Int32 = 10,
      @largest_consecutive_empty_record_count : Int32 = 32,
      @largest_consecutive_warning_alert_count : Int32 = 1,
      @largest_key_update_count_per_minute : Int32 = 32,
      @largest_skipped_early_data_bytesize : Int32 = 16_384,
      @handshake_timeout : Time::Span = 10.seconds,
    )
    end
  end
end
