require "http/server"
require "openssl/hmac"
require "../../grant"

module Grant
  module Middleware
    # Routes each request to the reading or writing role, as ActiveRecord's
    # `DatabaseSelector` does: GET and HEAD requests read from the replica
    # unless the same client wrote within `delay`, every other verb writes.
    #
    # The time of the last write is kept by a `LastWriteStore`. It is stored
    # only after a write request, and read requests only look at the store, so
    # a read-only request never serializes a session or sets a cookie.
    #
    # ```
    # store = Grant::Middleware::DatabaseSelector::CookieStore.new(secret: settings.secret)
    # handlers << Grant::Middleware::DatabaseSelector.new(store)
    # ```
    #
    # The role is applied with `Grant::Base.connected_to`, so it covers every
    # model. The reading role prevents writes; a write verb runs on the
    # writing role and records the timestamp before the downstream handlers
    # run, because response headers cannot change once a body is sent.
    class DatabaseSelector
      include HTTP::Handler

      # Where the time of a client's last write lives.
      abstract class LastWriteStore
        # When the client behind *request* last wrote, or `nil`.
        abstract def last_write_at(request : HTTP::Request) : Time?

        # Records that the client behind *context* wrote at *time*.
        abstract def record_write(context : HTTP::Server::Context, time : Time) : Nil
      end

      # Keeps the timestamp in a signed cookie, so no server-side session is
      # read or written. A missing, malformed, or forged cookie counts as no
      # recent write.
      class CookieStore < LastWriteStore
        getter cookie_name : String

        def initialize(@secret : String, @cookie_name : String = "grant_last_write", @path : String = "/", @secure : Bool = false)
        end

        def last_write_at(request : HTTP::Request) : Time?
          return unless cookie = request.cookies[@cookie_name]?

          value = cookie.value
          stamp, separator, signature = value.rpartition('.')
          return if separator.empty?
          return unless Crypto::Subtle.constant_time_compare(signature, sign(stamp))

          millis = stamp.to_i64? || return
          Time.unix_ms(millis)
        end

        def record_write(context : HTTP::Server::Context, time : Time) : Nil
          stamp = time.to_unix_ms.to_s
          context.response.cookies << HTTP::Cookie.new(
            @cookie_name, "#{stamp}.#{sign(stamp)}",
            path: @path, http_only: true, secure: @secure, samesite: HTTP::Cookie::SameSite::Lax)
        end

        private def sign(stamp : String) : String
          OpenSSL::HMAC.hexdigest(:sha256, @secret, stamp)
        end
      end

      # Keeps timestamps in a caller-supplied pair of procs, for apps whose
      # sessions live elsewhere.
      class ProcStore < LastWriteStore
        def initialize(@reader : Proc(HTTP::Request, Time?), @writer : Proc(HTTP::Server::Context, Time, Nil))
        end

        def last_write_at(request : HTTP::Request) : Time?
          @reader.call(request)
        end

        def record_write(context : HTTP::Server::Context, time : Time) : Nil
          @writer.call(context, time)
        end
      end

      # Chooses the role for a request: receives the request and the time of
      # the client's last write.
      alias Resolver = Proc(HTTP::Request, Time?, Symbol)

      getter delay : Time::Span

      def initialize(@store : LastWriteStore, @delay : Time::Span = 2.seconds,
                     @database : String? = nil, @writing_role : Symbol = Grant.settings.writing_role,
                     @reading_role : Symbol = Grant.settings.reading_role, @resolver : Resolver? = nil,
                     @clock : Proc(Time) = -> { Time.utc })
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        write = write_request?(request)
        role = role_for(request, write)
        # Recorded before the response starts; only ever after a write verb.
        @store.record_write(context, @clock.call) if write

        Grant::Base.connected_to(database: @database, role: role) do
          call_next(context)
        end
      end

      private def write_request?(request : HTTP::Request) : Bool
        !(request.method == "GET" || request.method == "HEAD")
      end

      private def role_for(request : HTTP::Request, write : Bool) : Symbol
        if resolver = @resolver
          return resolver.call(request, @store.last_write_at(request))
        end
        return @writing_role if write

        last_write = @store.last_write_at(request)
        if last_write && @clock.call - last_write < @delay
          @writing_role
        else
          @reading_role
        end
      end
    end
  end
end
