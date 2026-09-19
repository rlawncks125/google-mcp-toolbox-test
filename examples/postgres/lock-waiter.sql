SET lock_timeout = '25s';
BEGIN;
UPDATE observability_demo.orders
SET amount = amount + 10
WHERE id = 1;
ROLLBACK;
