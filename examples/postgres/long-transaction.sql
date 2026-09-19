BEGIN;
SELECT count(*) FROM observability_demo.orders WHERE status = 'paid';
SELECT pg_sleep(30);
ROLLBACK;
