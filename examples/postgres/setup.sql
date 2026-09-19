CREATE SCHEMA IF NOT EXISTS observability_demo;

CREATE TABLE IF NOT EXISTS observability_demo.orders (
  id bigint PRIMARY KEY,
  customer_id bigint NOT NULL,
  status text NOT NULL,
  amount numeric(12, 2) NOT NULL,
  created_at timestamptz NOT NULL
);

INSERT INTO observability_demo.orders (id, customer_id, status, amount, created_at)
SELECT
  value,
  (value % 1000) + 1,
  CASE value % 4
    WHEN 0 THEN 'pending'
    WHEN 1 THEN 'paid'
    WHEN 2 THEN 'shipped'
    ELSE 'cancelled'
  END,
  ((value % 50000) + 100)::numeric / 100,
  now() - make_interval(secs => value % 86400)
FROM generate_series(1, 50000) AS value
ON CONFLICT (id) DO NOTHING;

ANALYZE observability_demo.orders;
