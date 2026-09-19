BEGIN;
UPDATE observability_demo.orders
SET amount = amount + 1
WHERE id = 1;
SELECT pg_sleep(30);
ROLLBACK;
