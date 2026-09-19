SELECT
  queryid,
  calls,
  round(mean_exec_time::numeric, 3) AS mean_ms,
  round(max_exec_time::numeric, 3) AS max_ms,
  left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 120) AS normalized_query
FROM pg_stat_statements
WHERE query LIKE '%observability_demo.orders%'
  AND query LIKE '%pg_sleep%'
  AND query NOT LIKE '%pg_stat_statements%'
ORDER BY calls DESC
LIMIT 5;
