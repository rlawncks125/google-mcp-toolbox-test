.PHONY: init validate validate-dashboards up down ps logs reset \
	demo-postgres-lock demo-postgres-transaction \
	demo-redis demo-mongodb demo-mcp-concurrent demo-service demo-all

init:
	@test -f .env || cp .env.example .env

validate:
	docker compose config --quiet

validate-dashboards:
	node -e "for (const f of require('fs').readdirSync('grafana/dashboards').filter(f => f.endsWith('.json'))) JSON.parse(require('fs').readFileSync('grafana/dashboards/' + f)); console.log('dashboard JSON valid')"

up: init
	docker compose up -d

down:
	docker compose down

ps:
	docker compose ps

logs:
	docker compose logs -f toolbox otel-collector postgres-exporter redis-exporter mongodb-exporter

demo-postgres-lock: up
	./scripts/run-dashboard-demo.sh postgres-lock

demo-postgres-transaction: up
	./scripts/run-dashboard-demo.sh postgres-transaction

demo-redis: up
	./scripts/run-dashboard-demo.sh redis

demo-mongodb: up
	./scripts/run-dashboard-demo.sh mongodb

demo-mcp-concurrent: up
	./scripts/run-dashboard-demo.sh mcp-concurrent

demo-service: up
	sh ./scripts/run-demo-api-load.sh

demo-all: up
	./scripts/run-dashboard-demo.sh all
	sh ./scripts/run-demo-api-load.sh

# Explicit opt-in: this removes all local database and observability data.
reset:
	docker compose down --volumes
