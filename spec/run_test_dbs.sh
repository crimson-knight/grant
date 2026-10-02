#!/bin/bash

docker run --name mysql -d \
  -e MYSQL_ROOT_PASSWORD=password \
  -e MYSQL_DATABASE=grant_db \
  -e MYSQL_USER=grant \
  -e MYSQL_PASSWORD=password \
  -p 3306:3306 \
  mysql:8.0@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b

docker run --name psql -d \
  -e POSTGRES_USER=grant \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=grant_db \
  -p 5432:5432 \
  postgres:16@sha256:a3b7f434b2dc57ce85a67e171163eb8ab1a1ebcb39d27484661f26b1dfbe30d6
