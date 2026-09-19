#!/bin/sh
set -eu

psql --set=ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=toolbox_user="$TOOLBOX_DB_USER" \
  --set=toolbox_password="$TOOLBOX_DB_PASSWORD" <<'EOSQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'toolbox_user', :'toolbox_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'toolbox_user')
\gexec

SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'toolbox_user')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'toolbox_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'toolbox_user')
\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'toolbox_user')
\gexec
SELECT format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO %I', :'toolbox_user')
\gexec
SELECT format('GRANT pg_read_all_stats TO %I', :'toolbox_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO %I', :'toolbox_user')
\gexec
EOSQL

