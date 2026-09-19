#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workspace_dir"

postgres_psql() {
  docker compose exec -T postgres sh -c 'psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'
}

postgres_setup() {
  postgres_psql < examples/postgres/setup.sql
}

postgres_query() {
  postgres_setup
  for _ in $(seq 1 10); do
    postgres_psql < examples/postgres/selected-query.sql >/dev/null
  done
  echo "Demo query executed. Add one of these query IDs to the Prometheus allowlist:"
  postgres_psql < examples/postgres/find-query-id.sql
}

postgres_lock() {
  postgres_setup
  echo "Holding a row lock for 30 seconds; open the PostgreSQL dashboard now."
  postgres_psql < examples/postgres/lock-holder.sql >/dev/null &
  holder_pid=$!
  sleep 3
  postgres_psql < examples/postgres/lock-waiter.sql >/dev/null || true
  wait "$holder_pid"
  echo "Lock demo finished; all changes were rolled back."
}

postgres_transaction() {
  postgres_setup
  echo "Holding a transaction for 30 seconds; open the PostgreSQL dashboard now."
  postgres_psql < examples/postgres/long-transaction.sql >/dev/null
  echo "Long transaction demo finished; all changes were rolled back."
}

redis_workload() {
  echo "Generating Redis hits, misses, expirations, a slowlog entry, and a blocked client."
  docker compose exec -T redis sh -c '
    set -eu
    for i in $(seq 1 500); do
      redis-cli --no-auth-warning SET "observability:demo:$i" "value-$i" EX 300 >/dev/null
      redis-cli --no-auth-warning GET "observability:demo:$i" >/dev/null
      redis-cli --no-auth-warning GET "observability:missing:$i" >/dev/null
    done
    old_threshold=$(redis-cli --no-auth-warning --raw CONFIG GET slowlog-log-slower-than | tail -n 1)
    redis-cli --no-auth-warning CONFIG SET slowlog-log-slower-than 1000 >/dev/null
    redis-cli --no-auth-warning EVAL "local x=0 for i=1,500000 do x=x+i end return x" 0 >/dev/null
    redis-cli --no-auth-warning CONFIG SET slowlog-log-slower-than "$old_threshold" >/dev/null
  '
  docker compose exec -T redis redis-cli --no-auth-warning BLPOP observability:demo:block 15 >/dev/null &
  blocked_pid=$!
  sleep 3
  docker compose exec -T redis redis-cli --no-auth-warning LPUSH observability:demo:block release >/dev/null
  wait "$blocked_pid"
  echo "Redis demo finished; generated keys expire in five minutes."
}

mongodb_workload() {
  echo "Generating MongoDB read, write, aggregation, cache, and storage metrics."
  docker compose exec -T mongodb sh -c '
    mongosh --quiet \
      --username "$MONGO_INITDB_ROOT_USERNAME" \
      --password "$MONGO_INITDB_ROOT_PASSWORD" \
      --authenticationDatabase admin \
      --file /dev/stdin
  ' < examples/mongodb/workload.js
}

mcp_concurrent() {
  local endpoint="${TOOLBOX_MCP_URL:-http://127.0.0.1:5000/mcp/db-observability}"
  local failures=0
  local request_id
  local request_pid
  local -a request_pids=()

  echo "Sending 20 concurrent database_overview calls; each call should become a unique trace."
  for request_id in $(seq 1 20); do
    curl --fail --silent --show-error \
      --request POST "$endpoint" \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json, text/event-stream' \
      --data "{\"jsonrpc\":\"2.0\",\"id\":${request_id},\"method\":\"tools/call\",\"params\":{\"name\":\"database_overview\",\"arguments\":{}}}" \
      >/dev/null &
    request_pids+=("$!")
  done

  for request_pid in "${request_pids[@]}"; do
    wait "$request_pid" || failures=$((failures + 1))
  done

  if (( failures > 0 )); then
    echo "$failures concurrent MCP request(s) failed." >&2
    return 1
  fi
  echo "Concurrent MCP demo finished; open Request Correlation and click a Trace ID."
}

usage() {
  cat <<'EOF'
Usage: ./scripts/run-dashboard-demo.sh COMMAND

Commands:
  postgres-query        Generate a repeatable 200 ms query and print its queryid
  postgres-lock         Hold a row lock and a waiting UPDATE for 30 seconds
  postgres-transaction  Hold an open transaction for 30 seconds
  redis                 Generate command, cache, slowlog, and blocked-client metrics
  mongodb               Generate read/write/aggregation and storage metrics
  mcp-concurrent         Send 20 concurrent tool calls to verify trace isolation
  all                   Run query workloads, then the two PostgreSQL waits in parallel
EOF
}

case "${1:-}" in
  postgres-query) postgres_query ;;
  postgres-lock) postgres_lock ;;
  postgres-transaction) postgres_transaction ;;
  redis) redis_workload ;;
  mongodb) mongodb_workload ;;
  mcp-concurrent) mcp_concurrent ;;
  all)
    postgres_query
    mcp_concurrent
    redis_workload & redis_pid=$!
    mongodb_workload & mongo_pid=$!
    postgres_lock & lock_pid=$!
    postgres_transaction & transaction_pid=$!
    wait "$redis_pid" "$mongo_pid" "$lock_pid" "$transaction_pid"
    ;;
  *) usage; exit 2 ;;
esac
