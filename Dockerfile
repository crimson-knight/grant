FROM 84codes/crystal:latest-ubuntu-jammy@sha256:d6301cf70f759f7110f78ec47e663b323002d9f9a4214344c79c0ebb43ca2169

# Install deps
RUN apt-get update -qq && apt-get install -y --no-install-recommends libpq-dev libmysqlclient-dev libsqlite3-dev

WORKDIR /app/user

COPY shard.yml /app/user
COPY shard.lock /app/user
RUN shards install --frozen

COPY src /app/user/src
COPY spec /app/user/spec

ENTRYPOINT []
