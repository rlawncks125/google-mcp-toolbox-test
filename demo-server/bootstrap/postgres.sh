#!/bin/sh
set -eu

psql --set=ON_ERROR_STOP=1 \
  --host "$DB_HOST" \
  --username "$POSTGRES_USER" \
  --dbname "$DB_NAME" \
  --set=app_user="$APP_DB_USER" \
  --set=app_password="$APP_DB_PASSWORD" \
  --set=toolbox_user="$TOOLBOX_DB_USER" \
  --set=orders_reader_user="$ORDERS_READER_USER" \
  --set=orders_reader_password="$ORDERS_READER_PASSWORD" <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
\gexec

SELECT format('ALTER ROLE %I PASSWORD %L', :'app_user', :'app_password')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'orders_reader_user', :'orders_reader_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'orders_reader_user')
\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'orders_reader_user', :'orders_reader_password')
\gexec
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'orders_reader_user')
\gexec
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'orders_reader_user', '5s')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'orders_reader_user')
\gexec

CREATE SCHEMA IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_name text NOT NULL,
  total_cents integer NOT NULL CHECK (total_cents >= 0),
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO demo.orders (customer_name, total_cents, status)
SELECT seed.customer_name, seed.total_cents, seed.status
FROM (VALUES
  ('alice', 12900, 'paid'),
  ('alice', 5400, 'shipped'),
  ('bob', 21900, 'pending')
) AS seed(customer_name, total_cents, status)
WHERE NOT EXISTS (SELECT 1 FROM demo.orders);

SELECT format('GRANT USAGE ON SCHEMA demo TO %I', :'app_user')
\gexec
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO %I', :'app_user')
\gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA demo TO %I', :'app_user')
\gexec

SELECT format('GRANT USAGE ON SCHEMA demo TO %I', :'orders_reader_user')
\gexec
SELECT format('GRANT SELECT ON TABLE demo.orders TO %I', :'orders_reader_user')
\gexec

-- 테스트용 execute_query는 demo schema 전체를 조회할 수 있지만 쓰기는 DB role에서 차단합니다.
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'toolbox_user')
\gexec
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'toolbox_user', '5s')
\gexec
SELECT format('GRANT USAGE ON SCHEMA demo TO %I', :'toolbox_user')
\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA demo TO %I', :'toolbox_user')
\gexec
EOSQL
