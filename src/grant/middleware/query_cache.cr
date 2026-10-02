require "http/server"
require "../query_cache"

module Grant::Middleware
  # HTTP handler that turns the Grant query cache on for one request, so a
  # repeated read inside the request (a view that calls `User.find(id)` twice)
  # costs one statement. It is an ordinary `HTTP::Handler`, so it plugs into an
  # Amber V2 pipeline:
  #
  # ```
  # pipeline :web do
  #   plug Grant::Middleware::QueryCache.new
  # end
  # ```
  #
  # The cache belongs to the request's fiber and is dropped when the response
  # is done, also on an error. Any write, from this request or another, clears
  # it (see `Grant::QueryCache`).
  class QueryCache
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      Grant::QueryCache.cache { call_next(context) }
    end
  end
end
