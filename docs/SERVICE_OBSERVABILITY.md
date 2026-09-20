# Bun 서비스와 DB 요청 추적 가이드

## 구성 목적

`demo-server`는 실제 애플리케이션이 PostgreSQL, Redis, MongoDB를 호출할 때 어떤 데이터를 수집해야 하는지 보여주는 최소 Bun API입니다. HTTP 요청 span 아래에 각 DB client span이 생성되므로 한 Trace에서 서버 처리시간과 DB별 실행시간을 비교할 수 있습니다.

```text
GET /api/combined
  ├─ SELECT demo.orders          PostgreSQL
  ├─ GET/SET redis cache         Redis
  └─ find app.health_events      MongoDB
```

Trace와 metric은 OTLP/HTTP로 OpenTelemetry Collector에 전달됩니다. Trace는 Jaeger, metric은 Prometheus로 전달됩니다. JSON stdout 로그는 Alloy가 읽어 Loki로 전달합니다.

## 실행과 테스트

전체 환경을 시작합니다.

```bash
make up
make demo-service
```

`make demo-service`는 Prometheus가 여러 scrape 구간에서 변화량을 관측할 수 있도록 `/api/combined`를 기본 20회, 1초 간격으로 호출합니다. 요청 수, 간격과 주소는 변경할 수 있습니다.

```bash
DEMO_REQUEST_COUNT=50 make demo-service
DEMO_REQUEST_INTERVAL_SECONDS=0.2 make demo-service
DEMO_API_URL=http://server.example:3001 make demo-service
```

개별 DB 호출은 다음과 같이 테스트합니다.

```bash
curl 'http://127.0.0.1:3001/api/postgres/orders?customer=alice&delayMs=200'
curl 'http://127.0.0.1:3001/api/redis/cache/sample'
curl 'http://127.0.0.1:3001/api/mongodb/events?limit=10'
curl 'http://127.0.0.1:3001/api/combined?customer=alice&delayMs=300'
```

응답의 `x-trace-id` header를 사용하면 Jaeger에서 해당 요청을 바로 찾을 수 있습니다. `delayMs`는 PostgreSQL 병목을 재현하기 위한 값이며 0~2000ms로 제한됩니다.

- Grafana: `http://127.0.0.1:3000/d/application-service-db-tracing`
- Jaeger: `http://127.0.0.1:16686`, service `demo-api`
- API: `http://127.0.0.1:3001`

## 수집하는 데이터

| 신호 | 주요 필드 | 용도 |
|---|---|---|
| HTTP span | `service.name`, `http.route`, status, duration | 느린 서비스와 API 탐색 |
| DB span | `db.system.name`, `db.operation.name`, `db.query.summary`, duration | 요청 안에서 느린 DB 작업 탐색 |
| Metric | 서버가 관측한 서비스/route/DB 종류별 count, p95 | 장기 추이와 경보 |
| Log | `trace_id`, route, status, `duration_ms` | Trace와 로그 연결 |
| DB exporter | connection, lock, cache, I/O | DB 엔진 병목 원인 확인 |

SQL 원문, bind parameter, Redis key/value, MongoDB filter 값은 telemetry에 기록하지 않습니다. `db.query.summary`는 `SELECT demo.orders by customer`처럼 코드에서 관리하는 고정 문자열만 사용합니다.

## 서비스 구분 규칙

서비스가 늘어날 때 다음 리소스 속성을 공통 규칙으로 사용합니다.

| 속성 | 예 | 규칙 |
|---|---|---|
| `service.namespace` | `commerce` | 같은 제품/시스템 묶음 |
| `service.name` | `order-api` | 논리 서비스 이름. replica마다 바꾸지 않음 |
| `service.version` | `2026.09.19-1` | 배포 artifact 버전 |
| `service.instance.id` | pod/container ID | 실행 인스턴스 구분 |
| `deployment.environment.name` | `dev`, `stage`, `prod` | 환경 구분 |

URL의 사용자 ID나 주문 ID를 span 이름과 `http.route`에 넣지 않습니다. `/orders/123` 대신 `/orders/:id`처럼 route template을 사용해야 시계열 cardinality가 증가하지 않습니다.

Compose 환경에서는 Loki의 `service` label도 OTel `service.name`과 같게 맞춥니다.

```yaml
environment:
  OTEL_SERVICE_NAME: order-api
  OTEL_SERVICE_NAMESPACE: commerce
  OTEL_SERVICE_VERSION: 2026.09.19-1
  DEPLOYMENT_ENVIRONMENT: prod
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
labels:
  observability.logs: "true"
  observability.service_name: order-api
```

Kubernetes에서는 같은 값을 Deployment 환경변수와 resource attribute에 넣고, pod UID를 `service.instance.id`로 사용합니다.

## 실제 서비스에 적용하는 순서

1. 애플리케이션 시작 시 OTel SDK를 DB client보다 먼저 초기화합니다.
2. HTTP 요청에 SERVER span을 만들고 들어온 `traceparent`를 이어받습니다.
3. DB 호출에 CLIENT span을 만들고 `db.system.name`, `db.operation.name`, 낮은 cardinality의 `db.query.summary`를 기록합니다.
4. metric에는 route template과 고정된 DB operation만 label로 사용합니다.
5. 구조화 로그에 현재 `trace_id`와 `span_id`를 기록합니다.
6. Collector의 OTLP endpoint로 trace/metric을 전송합니다.

현재 예제 구현은 [telemetry.ts](../demo-server/src/telemetry.ts)와 [server.ts](../demo-server/src/server.ts)에 있습니다. 프레임워크나 ORM을 사용하는 서비스는 호환되는 OTel 자동 계측을 사용할 수 있지만, SQL 원문과 parameter 수집 설정은 반드시 별도로 검토합니다.

## 쿼리 병목 확인 순서

1. `Application / Service & DB Tracing`에서 service와 느린 route를 고릅니다.
2. `DB별·작업별 p95`에서 PostgreSQL, Redis, MongoDB 중 지연이 큰 대상을 확인합니다.
3. 최근 Trace를 열어 HTTP 전체 시간과 DB client span을 비교합니다.
4. 느린 DB CLIENT span의 operation과 고정 query summary로 호출 위치를 찾습니다.
5. 해당 DB의 Deep Dive에서 lock, connection, cache, disk 원인을 확인합니다.

Query 원문, queryid와 parameter는 DB나 Prometheus에 상시 수집하지 않습니다. OTel DB span은 서버 관점에서 한 요청의 DB 호출 시간과 성공/실패를 보여주고, DB exporter는 query 내용 없이 connection, lock, cache, I/O 같은 엔진 상태만 보여줍니다.

## 변경할 위치

- API/DB 작업: `demo-server/src/server.ts`
- 서비스 이름과 OTLP 전송: `demo-server/src/telemetry.ts`, `.env`
- 예제 DB 계정과 seed: `demo-server/bootstrap/`
- 컨테이너 연결: `docker-compose.yml`
- 서비스 대시보드: `grafana/dashboards/application-service-observability.json`

변경 후 다음 순서로 검증합니다.

```bash
cd demo-server && bun install && bun run check
cd ..
make validate
make validate-dashboards
docker compose up -d --build demo-api
make demo-service
```
