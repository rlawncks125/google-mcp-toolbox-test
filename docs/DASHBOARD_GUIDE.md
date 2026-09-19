# DB Dashboard 해설 및 테스트 가이드

## 테스트 명령

| 명령 | 만들어지는 신호 | 확인할 Dashboard |
|---|---|---|
| `make demo-postgres-query` | 약 200ms query 10회, `queryid` 출력 | Selected Query Performance |
| `make demo-postgres-lock` | 같은 row의 lock holder와 waiter를 30초 유지 | PostgreSQL Deep Dive |
| `make demo-postgres-transaction` | 열린 transaction을 30초 유지 | PostgreSQL Deep Dive |
| `make demo-redis` | hit/miss, SET/GET, slowlog, blocked client | Redis Deep Dive |
| `make demo-mongodb` | find, sort, aggregation, update, storage/cache | MongoDB Deep Dive |
| `make demo-mcp-concurrent` | MCP Tool 20개 동시 호출, 서로 다른 trace 20개 | Request Correlation |
| `make demo-all` | 위 workload를 함께 실행 | 모든 Dashboard |

Dashboard scrape 주기는 15초입니다. lock/transaction 테스트는 명령 실행 중에 dashboard를 열어야 값이 보입니다.

## Multi-DB Overview

세 DB와 MCP layer를 빠르게 확인하는 첫 화면입니다.

| Panel | 의미 |
|---|---|
| PostgreSQL / Redis / MongoDB | exporter가 DB에 연결할 수 있으면 UP입니다. 애플리케이션 query 성공을 보장하는 값은 아닙니다. |
| DB별 연결 수 | PostgreSQL backend, Redis client, MongoDB current connection 수입니다. 급격한 증가는 connection leak 가능성이 있습니다. |
| Redis memory / MongoDB connection | DB별 핵심 자원 사용량입니다. |
| MCP Tool별 실행률 | AI/MCP client가 어떤 Toolbox tool을 얼마나 호출하는지 보여줍니다. |
| DB 및 Toolbox 로그 | metric 이상 시 같은 시간대의 원본 container log를 확인합니다. |

## Request Correlation

동시에 들어온 요청은 로그 timestamp나 메시지 순서로 묶지 않습니다. Jaeger의 `traceID` 하나를 MCP 요청 하나의 경계로 사용하며, 최근 요청 표에서 trace ID를 누르면 해당 요청의 root span과 `tools/call` span이 하나의 waterfall로 열립니다.

| Panel | 의미와 해석 |
|---|---|
| Tool 호출률 | `tools/call` 요청의 초당 처리량입니다. |
| Tool 실행 p50/p95/p99 | 선택 시간대의 일반·느린·tail latency를 비교합니다. p95/p99만 오르면 일부 요청 또는 특정 Tool이 느린 상황입니다. |
| Tool 오류율 | 전체 Tool 호출 중 오류 span이 기록된 비율입니다. |
| 호출된 Tool 수 | 현재 metric에 나타나는 Tool 종류 수입니다. |
| Tool별 호출률 | 동시 부하가 어느 Tool에 집중되는지 보여줍니다. |
| Tool별 p95 실행시간 | `gen_ai_tool_name`별 p95입니다. 느린 DB 상태 조회를 찾는 주 패널입니다. |
| Latency percentile 추이 | 전체 Tool의 p50/p95/p99 변화를 함께 비교합니다. |
| 최근 요청 — trace별 그룹 | 한 행이 한 trace입니다. Trace ID, 시작시간, 요청 전체 duration을 표시하며 ID를 누르면 span waterfall로 이동합니다. |
| HTTP access log | status와 HTTP 응답시간을 보여주는 보조 로그입니다. Toolbox access log 자체에는 trace ID가 없으므로 이 로그를 요청 그룹의 기준으로 사용하지 않습니다. |

Loki에는 trace/request ID처럼 값 종류가 많은 필드를 index label로 넣지 않고 structured metadata로 저장합니다. 이는 요청별 검색 기능을 유지하면서 Loki stream cardinality 폭증을 피하기 위한 설정입니다. Toolbox가 trace ID를 포함해 출력한 로그는 해당 trace로 이동할 수 있지만, trace ID가 없는 DB 및 HTTP access log는 선택한 trace 시간 범위의 보조 자료로만 봅니다.

## PostgreSQL Deep Dive

| Panel | 의미와 해석 |
|---|---|
| 상태 | `pg_up`. DOWN이면 DB, credential, network부터 확인합니다. |
| 연결 사용률 | 현재 backend 수 / `max_connections`. 70%부터 주의, 85% 이상은 pool과 leak을 확인합니다. |
| Transaction/s | commit과 rollback의 초당 합계입니다. workload 변화 확인용입니다. |
| Rollback 비율 | 전체 transaction 중 rollback 비중입니다. 지속 상승하면 오류, timeout, 충돌을 확인합니다. |
| 최장 Transaction | 현재 열린 transaction의 최대 경과 시간입니다. 오래 유지되면 vacuum 방해와 lock 장기화를 유발할 수 있습니다. |
| 현재 Lock | lock mode 전체 개수입니다. lock 자체는 정상이며, 증가 추세와 대기 query를 함께 봅니다. |
| Transaction 처리율 | database별 commit/rollback 흐름입니다. |
| 세션 상태 | active, idle, idle in transaction을 구분합니다. `idle in transaction` 장기 지속이 특히 위험합니다. |
| Row 변경률 | insert/update/delete 처리량입니다. 갑작스러운 대량 변경을 찾습니다. |
| Buffer Cache Hit Ratio | shared buffer에서 처리된 비율입니다. 낮은 값이 지속되면 working set과 query/index를 확인합니다. |
| Lock Mode | access share, row exclusive 등 mode별 lock 수입니다. 원인 세션은 MCP `list_locks`로 확인합니다. |
| DB 크기 및 Temp 사용 | DB 크기와 5분간 임시파일 사용량입니다. temp 급증은 sort/hash spill 신호입니다. |
| Deadlock 및 Conflict | 최근 5분 증가량입니다. 0보다 크면 관련 transaction 순서와 lock을 조사합니다. |
| PostgreSQL 로그 | checkpoint, authentication, statement error 같은 근거를 확인합니다. |

상세 query 원문, lock holder PID, 실행 중 SQL은 metric label에 넣지 않습니다. 필요할 때 MCP `list_active_queries`, `long_running_transactions`, `list_locks`, `list_query_stats`를 호출합니다.

### PostgreSQL Lock Mode 읽는 법

`Lock Mode` panel은 주로 relation(table/index) 수준 lock을 mode별로 합산합니다. lock 개수가 있다는 사실만으로 장애는 아니며, **대기 세션이 생겼는지**, **얼마나 오래 지속되는지**, **어떤 transaction이 막고 있는지**를 함께 확인해야 합니다.

| Mode | 주로 발생하는 작업 | 해석 |
|---|---|---|
| `AccessShareLock` | 일반 `SELECT` | 가장 약한 table lock입니다. 평소에도 보이며 `ACCESS EXCLUSIVE`와만 충돌합니다. |
| `RowShareLock` | `SELECT ... FOR UPDATE/SHARE` | row를 잠글 가능성이 있는 조회입니다. 이름과 달리 relation-level lock 집계입니다. |
| `RowExclusiveLock` | `INSERT`, `UPDATE`, `DELETE` | 쓰기 작업의 정상적인 table lock입니다. 장기 유지되거나 대기가 동반될 때 조사합니다. |
| `ShareUpdateExclusiveLock` | `VACUUM`, `ANALYZE`, 일부 `CREATE INDEX` | 유지보수 작업끼리 충돌할 수 있습니다. 장기 vacuum/index 작업을 확인합니다. |
| `ShareLock` | 일반 `CREATE INDEX` 등 | 쓰기 계열 lock과 충돌해 DDL 중 변경 작업을 막을 수 있습니다. |
| `ShareRowExclusiveLock` | 일부 DDL·trigger 변경 | 강한 lock이며 동시 write를 제한합니다. 드물지만 지속되면 DDL 세션을 확인합니다. |
| `ExclusiveLock` | 일부 transaction/object 작업 | `AccessShareLock`은 허용하지만 대부분의 다른 mode와 충돌합니다. |
| `AccessExclusiveLock` | `ALTER TABLE`, `DROP`, `TRUNCATE`, `VACUUM FULL` | 가장 강한 lock으로 일반 `SELECT`도 막을 수 있습니다. 0이 아닌 상태가 지속되면 즉시 holder/waiter를 확인합니다. |
| `SIReadLock` | `SERIALIZABLE` predicate read | blocking lock이 아니라 직렬화 충돌을 판정하기 위한 predicate lock입니다. |

row lock 대기는 `transactionid` 또는 `tuple` lock으로 보일 수 있고 panel의 relation mode 합계만으로 holder를 특정할 수 없습니다. `make demo-postgres-lock` 실행 중 MCP `list_locks` 또는 `pg_stat_activity.wait_event_type = 'Lock'`을 함께 확인하세요.

## Selected Query Performance

`queryid` allowlist에 들어간 PostgreSQL query만 표시합니다.

| Panel | 의미와 해석 |
|---|---|
| 수집 중인 Query ID | 현재 Prometheus에 보이는 allowlist query 개수입니다. |
| 선택 Query 호출률 | allowlist 전체의 초당 실행 수입니다. |
| 평균 실행시간 | 누적 실행시간 증가율 / 호출 증가율입니다. p95가 아니라 5분 평균입니다. |
| 처리 Row/s | query가 반환하거나 처리한 row 증가율입니다. |
| Block Read 시간률 | query가 block read에 소비한 시간의 증가율입니다. I/O 병목 단서입니다. |
| 느린 Query Alert | 1초 평균 임계값을 넘겨 firing 중인 alert 수입니다. |
| Query ID별 호출률 | 어떤 query가 트래픽을 차지하는지 비교합니다. |
| Query ID별 평균 실행시간 | query별 평균 latency 추세입니다. |
| Query ID별 Rows/Call | 한 호출이 처리하는 row 규모입니다. 급증하면 조건 선택도 변화를 확인합니다. |
| Query ID별 Block I/O 시간률 | query별 read/write block I/O 시간입니다. |
| 관련 로그 | query 악화 시 Toolbox/PostgreSQL 로그를 같은 시간대에 봅니다. |

정확한 p95/p99는 `pg_stat_statements` 누적 counter만으로 계산할 수 없습니다. 분포가 필요하면 애플리케이션 OTel DB span histogram을 추가합니다.

## Redis Deep Dive

Redis의 `MULTI/EXEC`보다 운영에 더 중요한 command와 cache 동작을 중심으로 봅니다.

| Panel | 의미와 해석 |
|---|---|
| 상태 | `redis_up`. DOWN이면 인증과 address를 확인합니다. |
| 연결 Client | 현재 연결 수입니다. `maxclients` 대비 급증을 봅니다. |
| Command/s | 전체 command 처리율입니다. |
| Cache Hit Ratio | 누적 hit / (hit + miss). 낮으면 key 정책과 TTL을 확인합니다. |
| 사용 메모리 | Redis allocator가 사용하는 메모리입니다. |
| Memory Fragmentation | RSS 대비 allocator 사용 비율입니다. 1보다 너무 크면 allocator fragmentation 가능성이 있습니다. 작은 test instance에서는 과장될 수 있습니다. |
| Command별 처리율 | GET, SET 등 command별 호출량입니다. |
| Command 평균 지연 | command별 누적 실행시간 / 호출 수입니다. network 왕복시간은 포함하지 않습니다. |
| Command 오류 및 거부 | failed/rejected command 증가율입니다. ACL, type error, 잘못된 command를 확인합니다. |
| Memory 사용량 | logical used memory, RSS, 설정된 maxmemory를 비교합니다. maxmemory=0이면 max 선은 표시되지 않습니다. |
| Keyspace | DB 번호별 key와 TTL이 있는 key 수입니다. |
| Hit/Miss/Eviction/Expiration | cache 효율과 memory pressure, TTL churn을 확인합니다. |
| Network I/O | input/output byte rate입니다. |
| 지연 및 영속성 이상 징후 | blocked client, slowlog, AOF pending fsync, RDB 미저장 변경을 함께 봅니다. |
| Redis 로그 | persistence, OOM, restart 근거를 확인합니다. |

`SLOWLOG`의 실행시간은 command 실행시간이며 client network 시간은 제외합니다. 테스트 key는 `observability:demo:*`이고 5분 후 자동 만료됩니다.

## MongoDB Deep Dive

| Panel | 의미와 해석 |
|---|---|
| 상태 | `mongodb_up`. DOWN이면 URI, authSource, monitor role을 확인합니다. |
| 현재 연결 | serverStatus의 current connection입니다. |
| Operation/s | query, insert, update, delete, command 처리율 합계입니다. |
| 평균 Operation 지연 | operation 누적 latency / operation 수이며 단위는 microsecond입니다. |
| 열린 Transaction | multi-document application transaction 수입니다. standalone에서는 항상 0입니다. |
| Lock 대기 Queue | reader/writer가 global lock을 기다리는 수입니다. 지속적으로 0보다 크면 병목을 조사합니다. |
| Operation 유형별 처리율 | query/insert/update/delete/command별 workload입니다. |
| Operation 유형별 평균 지연 | read/write/command/transaction 평균 latency입니다. |
| Application Transaction 처리율 | 시작, commit, abort된 multi-document transaction 비율입니다. |
| 현재 Transaction 상태 | active, inactive, prepared transaction입니다. |
| WiredTiger Transaction Tickets | read/write 동시 작업 ticket의 available/in-use 값입니다. available 고갈은 storage contention 신호입니다. |
| WiredTiger Cache 및 Resident Memory | cache used/max와 process resident memory를 비교합니다. |
| Lock Queue 및 사용 중 Ticket | lock wait와 storage-engine 동시 작업을 함께 봅니다. |
| Database 저장공간 | database별 data, index, allocated storage입니다. |
| Document 처리 및 Operation 이상 | returned/inserted/updated/deleted와 scanAndOrder/writeConflict 증가율입니다. |
| Network Request Rate | MongoDB request 처리율입니다. |
| MongoDB 로그 | slow operation, storage, connection 오류의 근거입니다. |

현재 Compose의 MongoDB는 standalone이므로 multi-document transaction panel이 0인 것이 정상입니다. transaction 테스트가 필요하면 replica set 구성이 먼저 필요합니다. WiredTiger transaction은 storage-engine 내부 transaction이며 application transaction과 같은 의미가 아닙니다.

MongoDB 테스트 collection은 `observability_demo_orders`입니다. 삭제하려면 다음 명령을 실행합니다.

```bash
docker compose exec -T mongodb sh -c \
  'mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval "db.observability_demo_orders.drop()"'
```
