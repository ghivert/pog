#!/bin/sh

set -eu

echo
echo Resetting database

psql <<SQL
SELECT 'CREATE DATABASE gleam_pog_test'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = 'gleam_pog_test'
)\\gexec
SQL

psql -v "ON_ERROR_STOP=1" -d gleam_pog_test <<SQL
DROP TABLE IF EXISTS pets;
DROP TABLE IF EXISTS owners;
DROP TABLE IF EXISTS cats;
CREATE TABLE cats (
  id SERIAL PRIMARY KEY,
  name VARCHAR(50) NOT NULL,
  is_cute boolean NOT NULL DEFAULT true,
  colors VARCHAR(50)[] NOT NULL,
  last_petted_at TIMESTAMP NOT NULL,
  birthday DATE NOT NULL
);
CREATE TABLE owners (
  id SERIAL PRIMARY KEY
);
CREATE TABLE pets (
  id SERIAL PRIMARY KEY,
  owner_id INTEGER NOT NULL REFERENCES owners(id),
  age INTEGER NOT NULL CHECK (age >= 0)
);
SQL

echo Done
echo
