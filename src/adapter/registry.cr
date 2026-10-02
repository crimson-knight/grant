require "./base"

module Grant
  # Raised when a URL scheme or adapter name has no adapter registered for it,
  # usually because the matching `require "grant/adapter/<name>"` is missing.
  class UnknownAdapterError < Grant::ErrorBase
  end

  module Adapter
    # Maps URL schemes and adapter names (`"postgres"`, `"sqlite3"`, ...) to
    # adapter classes.
    #
    # The registry is populated by requires: each adapter file registers itself
    # when it is required, so an adapter that is never required is never
    # compiled into the program (a build that only needs SQLite pulls in no
    # PostgreSQL driver). Register a custom adapter the same way:
    #
    # ```
    # Grant::Adapter::Registry.register(MyAdapter, "mydb")
    # ```
    module Registry
      @@adapters = {} of String => Grant::Adapter::Base.class
      # Guards `@@adapters`: `register` is public, so a custom adapter can be
      # registered while other fibers resolve URLs.
      @@adapters_mutex = Mutex.new

      # Registers *adapter* under one or more scheme/name aliases.
      def self.register(adapter : Grant::Adapter::Base.class, *names : String) : Nil
        @@adapters_mutex.synchronize do
          names.each { |name| @@adapters[name.downcase] = adapter }
        end
      end

      # The adapter registered for *name* or `nil`.
      def self.for_scheme?(name : String) : Grant::Adapter::Base.class | Nil
        @@adapters_mutex.synchronize { @@adapters[name.downcase]? }
      end

      # The adapter registered for *name*; raises `UnknownAdapterError`.
      def self.for_scheme(name : String) : Grant::Adapter::Base.class
        for_scheme?(name) || raise UnknownAdapterError.new(
          "No adapter is registered for #{name.inspect} (registered: #{names.join(", ")}). " \
          "Require the adapter, e.g. require \"grant/adapter/pg\".")
      end

      # The scheme of *url* (`"postgres"` for `postgres://h/db`, `"sqlite3"`
      # for `sqlite3:./a.db`), or `nil` when it has none.
      def self.scheme_of(url : String) : String?
        if match = url.match(/\A([A-Za-z][A-Za-z0-9+.\-]*):/)
          match[1].downcase
        end
      end

      # The adapter class for *url*, chosen from its scheme.
      def self.for_url(url : String) : Grant::Adapter::Base.class
        scheme = scheme_of(url) || raise UnknownAdapterError.new(
          "Cannot infer an adapter: #{redact(url).inspect} has no URL scheme")
        for_scheme(scheme)
      end

      # Every registered scheme/name, sorted.
      def self.names : Array(String)
        @@adapters_mutex.synchronize { @@adapters.keys }.sort!
      end

      # Removes credentials from a URL before it goes into a message.
      def self.redact(url : String) : String
        # Greedy up to the last "@" before any query or fragment, so a password
        # holding "/" or "@" is still hidden.
        url.sub(/\A([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^?#]*@/, "\\1***@")
      end
    end
  end

  # The adapter class registered for a URL *scheme* (`"postgres"`, `"mysql"`,
  # `"sqlite3"`).
  def self.adapter_for_scheme(scheme : String) : Grant::Adapter::Base.class
    Adapter::Registry.for_scheme(scheme)
  end
end
