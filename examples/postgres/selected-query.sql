-- This exact statement is the demo query tracked through pg_stat_statements.
-- pg_sleep makes its latency visible without relying on machine speed.
SELECT pg_sleep(0.2), count(*) AS pending_orders
FROM observability_demo.orders
WHERE status = 'pending';
