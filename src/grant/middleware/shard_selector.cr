require "http/server"
require "../../grant"

module Grant
  module Middleware
    # Picks the shard for each request, for example from a subdomain, and by
    # default pins it: `Grant::Base.prohibit_shard_swapping` makes any code
    # that tries to `connected_to(shard: ...)` elsewhere during the request
    # raise `Grant::ShardSwappingProhibited`.
    #
    # ```
    # SHARDS = {"acme" => :shard_one, "globex" => :shard_two}
    # resolver = ->(request : HTTP::Request) { SHARDS[request.headers["Host"].split('.').first]? }
    # handlers << Grant::Middleware::ShardSelector.new(resolver)
    # ```
    #
    # A resolver returning `nil` leaves the request on the default shard.
    class ShardSelector
      include HTTP::Handler

      alias Resolver = Proc(HTTP::Request, Symbol?)

      getter? lock : Bool

      def initialize(@resolver : Resolver, @lock : Bool = true)
      end

      def call(context : HTTP::Server::Context) : Nil
        unless shard = @resolver.call(context.request)
          call_next(context)
          return
        end

        Grant::Base.connected_to(shard: shard) do
          if @lock
            Grant::Base.prohibit_shard_swapping { call_next(context) }
          else
            call_next(context)
          end
        end
      end
    end
  end
end
