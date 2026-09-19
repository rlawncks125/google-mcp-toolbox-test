# MCP Toolbox Multi-DB 관측 환경

Google MCP Toolbox로 PostgreSQL, Redis, MongoDB 상태를 대화형으로 점검하고, 같은 시스템을 지속적으로 관측하기 위한 로컬/개발용 스택입니다.

## 구성과 역할

| 구성 요소 | 역할 |
|---|---|
| MCP Toolbox | 세 DB의 제한된 상태 조회 도구 제공, MCP 요청/도구 실행 metric·trace 생성 |
| OpenTelemetry Collector | Toolbox의 OTLP metric·trace를 중앙 수집 및 라우팅 |
| DB exporters | PostgreSQL, Redis, MongoDB 엔진 상태를 Prometheus metric으로 변환 |
| Prometheus | Toolbox/DB metric 저장, alert rule 평가 |
| Jaeger | 분산 trace 저장 및 조회 |
| Loki + Grafana Alloy | Toolbox와 세 DB의 Docker stdout 로그 수집/저장 |
| Grafana | metric, log, trace를 한 화면에서 조회 |

중요: Toolbox telemetry는 MCP 호출과 도구 실행을 관측하며, DB 자체의 상시 상태 수집을 대체하지 않습니다. 그래서 DB마다 exporter를 함께 사용합니다.

## 빠른 시작

필수 조건은 Docker Engine과 Docker Compose v2입니다.

```bash
make init
# .env의 비밀번호를 변경
make validate
make up
```

접속 주소:

- Toolbox MCP: `http://127.0.0.1:5000/mcp/db-observability`
- Grafana: `http://127.0.0.1:3000`
- Prometheus: `http://127.0.0.1:9090`
- Jaeger: `http://127.0.0.1:16686`

Grafana에는 다음 대시보드와 Prometheus, Loki, Jaeger 데이터 소스가 자동 등록됩니다.

- `MCP Toolbox / Multi-DB Overview`: 세 DB 가용성과 핵심 지표 요약
- `MCP Toolbox / Request Correlation`: 동시 요청을 trace ID별로 분리하고 요청별 duration과 Tool latency 확인
- `MCP Toolbox / PostgreSQL Deep Dive`: transaction, rollback, 장기 transaction, session, lock, row 변경, cache hit, temp I/O, deadlock
- `MCP Toolbox / Selected Query Performance`: allowlist에 등록한 PostgreSQL `queryid`의 호출률, 평균 실행시간, rows/call, block I/O
- `MCP Toolbox / Redis Deep Dive`: command 처리율/지연/오류, memory, keyspace, hit/miss, eviction, persistence
- `MCP Toolbox / MongoDB Deep Dive`: operation/지연, application transaction, WiredTiger ticket/cache, lock queue, 저장공간
- `MCP Toolbox / PostgreSQL Overview`: 기존 PostgreSQL 및 MCP 실행 지표

Overview 상단 링크에서 각 Deep Dive로 이동할 수 있습니다. 초기 Grafana 계정은 `.env`의 `GRAFANA_ADMIN_USER`와 `GRAFANA_ADMIN_PASSWORD`입니다.

상세한 panel 해설과 안전한 테스트 workload는 [`docs/DASHBOARD_GUIDE.md`](docs/DASHBOARD_GUIDE.md), query ID 추가·삭제 및 dashboard 변경 절차는 [`docs/QUERY_MONITORING.md`](docs/QUERY_MONITORING.md)를 참고하세요.

MCP 클라이언트 예시:

```json
{
  "mcpServers": {
    "db-observability": {
      "type": "http",
      "url": "http://127.0.0.1:5000/mcp/db-observability"
    }
  }
}
```

연결 후 다음과 같이 요청할 수 있습니다.

- "현재 DB 연결 사용률과 서버 상태를 보여줘"
- "5분 넘게 열린 트랜잭션과 대기 중인 lock을 찾아줘"
- "누적 실행 시간이 큰 쿼리와 테이블 통계를 분석해줘"
- "Redis 메모리, 연결, 영속성, 복제 상태와 slow log를 확인해줘"
- "MongoDB의 최근 health event와 상태별 집계를 보여줘"

등록된 추가 도구는 `redis_overview`, `redis_slowlog`, `redis_latency`, `mongo_recent_health_events`, `mongo_health_event_summary`입니다. 모두 같은 `db-observability` MCP endpoint에서 제공됩니다.

## 보안 기본값

- 전용 `toolbox_reader` 계정은 `default_transaction_read_only=on`, 읽기 권한과 `pg_read_all_stats`만 가집니다.
- MongoDB의 `toolbox_monitor` 계정은 `clusterMonitor`와 대상 DB의 `read` 역할만 가집니다.
- Redis는 임의 명령 입력을 받지 않고 설정에 고정된 상태 조회 명령만 Toolbox에 노출합니다. 운영에서는 별도 ACL 사용자도 적용하세요.
- Toolbox에는 임의 SQL 실행 도구를 노출하지 않고 상태 조회 도구만 등록했습니다.
- 모든 호스트 포트는 `127.0.0.1`에만 bind합니다.
- 운영에서는 Toolbox 앞에 TLS/OIDC 인증 reverse proxy를 두고, Docker socket을 읽는 Alloy를 별도 노드 에이전트 권한으로 격리하세요.
- 쿼리 텍스트가 MCP 응답이나 DB 통계에 포함될 수 있으므로 민감 정보가 SQL literal에 들어가지 않도록 parameterized query를 사용하세요.

## 기존 DB에 연결

이 저장소의 세 DB는 실행 가능한 예제입니다. 기존 인스턴스를 사용하려면 `.env`의 `DB_*`, `REDIS_*`, `MONGO_*` 값을 변경하세요. 원격 PostgreSQL 계정에는 최소한 다음 원칙을 적용합니다.

```sql
ALTER ROLE toolbox_reader SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE your_database TO toolbox_reader;
GRANT USAGE ON SCHEMA public TO toolbox_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO toolbox_reader;
GRANT pg_read_all_stats TO toolbox_reader;
```

외부 DB만 사용할 때에는 `docker-compose.yml`의 해당 DB 서비스와 Toolbox/exporter의 `depends_on` 항목을 제거하십시오. PostgreSQL TLS는 `DB_SSLMODE`, MongoDB TLS 옵션은 `toolbox/tools.yaml`의 URI, Redis TLS는 Redis source 설정에 조직 정책대로 반영합니다.

## 운영 적용 판단

기존 OTel + Grafana + Loki + Jaeger + Prometheus 조합은 그대로 유지하는 편이 합리적입니다. DB가 늘어나도 exporter와 대시보드만 확장하면 되고, OTel Collector를 단일 진입점으로 두었기 때문에 backend를 바꿔도 Toolbox 설정은 유지됩니다.

다만 운영 환경에서는 다음을 검토하세요.

- Jaeger를 이미 안정적으로 운영한다면 유지합니다. Grafana 한 화면과 장기 보관을 더 중시하면 Jaeger 대신 Tempo로 단순화할 수 있습니다.
- Loki는 애플리케이션 로그용입니다. 모든 SQL 본문을 로깅하면 개인정보·credential과 저장 비용 위험이 있으므로 기본 구성에서는 활성화하지 않았습니다.
- Prometheus alert는 현재 로컬 PostgreSQL의 `max_connections=100`을 가정해 연결 수 임계값을 80으로 뒀습니다. 실제 DB 한도와 SLO에 맞게 수정하세요.
- 이 Compose는 단일 노드 개발/검증용입니다. 운영에서는 backend별 영속 스토리지, HA, retention, 인증, alert 전달용 Alertmanager가 별도로 필요합니다.

## 문제 확인

```bash
docker compose ps
docker compose logs toolbox otel-collector postgres-exporter redis-exporter mongodb-exporter
curl -fsS http://127.0.0.1:9090/-/healthy
curl -fsS http://127.0.0.1:3100/ready
```

초기화 스크립트는 PostgreSQL/MongoDB 데이터 볼륨이 처음 생성될 때만 실행됩니다. DB 사용자/비밀번호를 바꾼 뒤 기존 개발 데이터를 버리고 다시 초기화하려는 경우에만 `make reset && make up`을 사용하세요. `make reset`은 모든 로컬 DB와 관측 데이터를 삭제합니다.
