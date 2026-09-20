#!/bin/sh
set -eu

base_url="${DEMO_API_URL:-http://127.0.0.1:3001}"
request_count="${DEMO_REQUEST_COUNT:-20}"
request_interval="${DEMO_REQUEST_INTERVAL_SECONDS:-1}"
i=1

while [ "$i" -le "$request_count" ]; do
  delay_ms=$((50 + (i % 5) * 50))
  curl -fsS "${base_url}/api/combined?customer=alice&delayMs=${delay_ms}" >/dev/null
  i=$((i + 1))
  if [ "$i" -le "$request_count" ]; then
    sleep "$request_interval"
  fi
done

echo "Generated ${request_count} traced requests against ${base_url}/api/combined"
echo "Grafana: http://127.0.0.1:3000/d/application-service-db-tracing"
echo "Jaeger service: demo-api"
