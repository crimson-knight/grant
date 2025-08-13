#!/bin/bash

MYSQL_VERSION=${MYSQL_VERSION:-5.7}
PG_VERSION=${PG_VERSION:-15.2}

docker run --name mysql -d \
  -e MYSQL_ROOT_PASSWORD=password \
  -e MYSQL_DATABASE=grant_db \
  -e MYSQL_USER=grant \
  -e MYSQL_PASSWORD=password \
  -p 3306:3306 \
  mysql:${MYSQL_VERSION}

docker run --name psql -d \
  -e POSTGRES_USER=grant \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=grant_db \
  -p 5432:5432 \
  postgres:${PG_VERSION}
