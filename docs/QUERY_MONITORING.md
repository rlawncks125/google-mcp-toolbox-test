# 선택 Query 성능 수집 운영 가이드

## 목표와 범위

이 구성은 PostgreSQL의 모든 SQL 원문을 저장하지 않습니다. `pg_stat_statements`가 만든 숫자형 `queryid` 중 allowlist에 등록한 항목만 Prometheus에 보관합니다.

수집하는 값은 호출 수, 누적 실행시간, 처리 row 수, block read/write 시간입니다. 평균 실행시간과 rows/call은 PromQL에서 계산합니다. SQL literal과 원문은 Prometheus label에 포함하지 않습니다.

데이터 흐름은 다음과 같습니다.

```text
PostgreSQL pg_stat_statements
  -> postgres_exporter --collector.stat_statements
  -> Prometheus metric_relabel allowlist
  -> Selected Query Performance dashboard / alert
```

`postgres` scrape job은 allowlist와 일치하는 series에만 `query_scope="selected"` label을 붙이고, 나머지 `pg_stat_statements_*` series를 버립니다. 일반 PostgreSQL metric과 선택 query metric을 한 번의 scrape로 처리하므로 exporter를 중복 호출하지 않습니다.

## 빠른 테스트

다음 명령은 `observability_demo.orders`를 만들고 약 200ms가 걸리는 같은 query를 10회 실행합니다.

```bash
make demo-postgres-query
```

현재 로컬 환경에서 생성된 데모 query ID는 `7814683544229287637`이며 [prometheus.yml](../prometheus/prometheus.yml)에 등록되어 있습니다. PostgreSQL 재초기화, 버전 변경 또는 query 구조 변경 후에는 ID가 달라질 수 있으므로 출력된 새 ID로 교체해야 합니다.

Prometheus가 설정을 다시 읽은 뒤 아래 대시보드에서 확인합니다.

```text
http://127.0.0.1:3000/d/mcp-selected-query-performance
```

테스트 데이터를 지우려면 다음 명령을 사용합니다.

```bash
docker compose exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP SCHEMA IF EXISTS observability_demo CASCADE"'
```

## 운영 Query ID 찾기

먼저 대상 query가 실제로 한 번 이상 실행되어야 합니다. 그 다음 로컬 관리자 세션에서 후보를 조회합니다.

```sql
SELECT
  queryid,
  calls,
  round(mean_exec_time::numeric, 3) AS mean_ms,
  round(max_exec_time::numeric, 3) AS max_ms,
  left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 160) AS normalized_query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 30;
```

원문 확인은 ID를 고르는 관리자 화면에서만 수행하며 Prometheus에는 전달되지 않습니다. Toolbox의 `list_query_stats`로 후보를 찾을 수도 있습니다.

다음 사항에 유의합니다.

- literal만 다른 같은 구조의 query는 보통 같은 `queryid`로 정규화됩니다.
- SQL 구조, PostgreSQL major version 또는 일부 planner 설정이 바뀌면 ID가 달라질 수 있습니다.
- `pg_stat_statements_reset()`을 실행하면 누적 counter가 초기화되어 그래프에 일시적인 reset이 나타납니다.
- password, token, 개인정보를 SQL comment나 literal에 넣지 않습니다.

## Allowlist 추가·수정·삭제

[prometheus/prometheus.yml](../prometheus/prometheus.yml)의 `postgres` job 첫 번째 `metric_relabel_configs` 정규식을 수정합니다.

한 개만 수집:

```yaml
regex: 'pg_stat_statements_.+;(7814683544229287637)'
```

여러 개 수집:

```yaml
regex: 'pg_stat_statements_.+;(7814683544229287637|-1234567890123456789|987654321)'
```

ID는 `|`로 구분하며 음수 부호도 그대로 입력합니다. 모든 query 수집을 뜻하는 `.*`는 사용하지 않습니다.

변경 후 검증하고 반영합니다.

```bash
make validate
docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose exec -T prometheus promtool check rules /etc/prometheus/alerts.yml
docker compose restart prometheus
```

삭제는 정규식에서 해당 ID만 제거하면 됩니다. 마지막 ID를 제거할 때는 존재하지 않는 sentinel인 `(0)`을 사용하면 dashboard는 0을 표시하고 query metric은 저장하지 않습니다.

## 임계값 변경

기본 alert는 선택 query의 5분 평균 실행시간이 1초를 5분간 초과할 때 발생합니다.

[prometheus/alerts.yml](../prometheus/alerts.yml)의 다음 값을 업무 SLO에 맞게 변경합니다.

```yaml
> 1
for: 5m
```

Dashboard 색상 임계값은 [selected-query-performance.json](../grafana/dashboards/selected-query-performance.json)의 `평균 실행시간` panel에서 별도로 변경합니다. Alert와 dashboard 임계값을 함께 수정해야 표시와 경보가 일치합니다.

## Dashboard 수정 절차

Grafana UI에서 provisioned dashboard를 직접 수정한 내용은 파일 provisioning에 의해 덮어써질 수 있습니다. 저장소의 JSON을 원본으로 관리합니다.

1. `grafana/dashboards/*.json`을 수정합니다.
2. JSON 문법을 확인합니다.

   ```bash
   make validate-dashboards
   ```

3. 약 30초 동안 provisioning을 기다리거나 Grafana를 재시작합니다.

   ```bash
   docker compose restart grafana
   ```

4. Grafana에서 시간 범위와 PromQL 결과를 확인합니다.

새 query panel에서는 반드시 `job="postgres",query_scope="selected"` 조건을 사용해야 allowlist metric만 조회합니다.

## Redis와 MongoDB의 Query 추적 범위

Redis는 SQL query ID가 없으므로 command 종류별 호출량·평균 지연·실패와 `SLOWLOG`만 수집합니다. 실제 key나 value는 metric에 넣지 않습니다.

MongoDB 기본 dashboard는 operation 종류와 application transaction, WiredTiger 상태를 집계합니다. query document 전체나 filter 값은 저장하지 않습니다. 특정 MongoDB query shape를 추적해야 한다면 애플리케이션 OTel span의 `db.query.summary` 같은 낮은 cardinality 속성을 allowlist하고, `db.statement` 원문은 수집하지 않는 방식을 권장합니다.

## 문제 해결

Dashboard가 0 또는 No data이면 다음 순서로 확인합니다.

1. 대상 query를 최근 5분 안에 여러 번 실행했는지 확인합니다.
2. `pg_stat_statements`에 현재 ID가 있는지 다시 조회합니다.
3. allowlist 정규식의 음수 부호와 `|` 구분자를 확인합니다.
4. Prometheus target과 metric을 확인합니다.

   ```bash
   curl -G 'http://127.0.0.1:9090/api/v1/query' \
     --data-urlencode 'query=pg_stat_statements_calls_total{job="postgres",query_scope="selected"}'
   ```

5. exporter와 Prometheus 로그를 확인합니다.

   ```bash
   docker compose logs postgres-exporter prometheus
   ```

평균은 누적값 자체가 아니라 5분 `rate()`로 계산합니다. 호출이 매우 드문 query는 짧은 시간 범위에서 값이 비어 보일 수 있으며, 이 경우 dashboard 시간 범위를 늘리거나 query를 다시 실행합니다.
