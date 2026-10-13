#!/bin/sh
# Patroni post_bootstrap (cluster/patroni/patroni.yml): runs once, as the superuser, on the Pi that
# initialises the cluster. Creates the backend's role and database "canary". $1 is Patroni's
# connection URL (no password in it). psql's \getenv reads CANARY_DB_PASSWORD from the
# environment, so the password never appears on a command line (ps) or in the SQL text.
set -eu

[ -n "${CANARY_DB_PASSWORD:-}" ] || {
  echo "canary-post-bootstrap: error: CANARY_DB_PASSWORD is not set" >&2
  exit 1
}

psql --no-psqlrc -v ON_ERROR_STOP=1 -d "$1" <<'SQL'
\getenv canary_password CANARY_DB_PASSWORD
SELECT 'CREATE ROLE canary LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'canary')\gexec
ALTER ROLE canary WITH LOGIN PASSWORD :'canary_password';
SELECT 'CREATE DATABASE canary OWNER canary' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'canary')\gexec
SQL
