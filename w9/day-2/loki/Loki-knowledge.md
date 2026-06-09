# Loki — Lý thuyết & Cú pháp

---

## 1. Loki là gì?

**Loki** là log aggregation system, được thiết kế theo cách tương tự Prometheus — chỉ index **labels** (metadata) thay vì full-text indexing.

```
┌──────────────────────────────────────────────────────────────┐
│                 LOGKEEPER vs ELK                             │
├──────────────────────────────────────────────────────────────┤
│  ELK (Elasticsearch):                                        │
│    - Full-text search mạnh mẽ                              │
│    - Index toàn bộ log content → TỐN RAM & DISK            │
│    - Chi phí cao khi log volume lớn                        │
│                                                              │
│  Loki:                                                       │
│    - Chỉ index labels (metadata) → RẺ ✅                   │
│    - Log content được chunked + compressed (object store)   │
│    - Tìm kiếm nhanh theo labels, sau đó fetch raw logs      │
│    - Chi phí cực rẻ: chỉ ~10% chi phí ELK cho cùng volume  │
└──────────────────────────────────────────────────────────────┘
```

**Đặc điểm:**

- **Label-based indexing**: Chỉ index labels (service, namespace, level...)
- **Log chunks**: Log được split thành chunks, nén, lưu ở object store
- **Prometheus-compatible**: Dùng same label model, PromQL-like syntax (LogQL)
- **Grafana integration**: Explore logs, correlate với metrics/traces

---

## 2. Kiến trúc Loki

```
┌──────────────────────────────────────────────────────────────────┐
│                         LOKI ARCHITECTURE                        │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │                  DISTRIBUTED MODE                         │  │
│   │                                                           │  │
│   │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐  │  │
│   │  │  Distributor│──▶│  Ingester   │──▶│  Compactor   │  │  │
│   │  │  (write)    │   │  (store logs│   │  (compact   │  │  │
│   │  └──────┬──────┘   │  + build    │   │  indexes)   │  │  │
│   │          │          │  indexes)   │   └─────────────┘  │  │
│   │          │          └──────┬──────┘                     │  │
│   │          │                 │                             │  │
│   │          │     ┌───────────┴───────────┐                │  │
│   │          │     ▼                       ▼                │  │
│   │          │  ┌──────────┐      ┌──────────────┐          │  │
│   │          │  │ Object   │      │  Cassandra /  │          │  │
│   │          │  │ Store   │      │  DynamoDB /   │          │  │
│   │          │  │(S3/GCS) │      │  BigTable     │          │  │
│   │          │  │(chunks) │      │  (indexes)    │          │  │
│   │          │  └──────────┘      └──────────────┘          │  │
│   │          │                                          │  │
│   │          ▼                                              │  │
│   │  ┌─────────────┐   ┌─────────────┐                      │  │
│   │  │   Querier   │◀──│  Ruler     │                      │  │
│   │  │  (read +   │   │  (alerts on│                      │  │
│   │  │   query)    │   │   logs)    │                      │  │
│   │  └──────┬──────┘   └─────────────┘                      │  │
│   └──────────┼───────────────────────────────────────────────┘  │
│              ▼                                                      │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │                    GRAFANA                                │  │
│   │  Explore Logs | LogQL Queries | Correlate w/ Metrics    │  │
│   └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. Promtail — Log Agent

**Promtail** là agent của Loki, chạy trên Kubernetes để thu thập logs và gửi đến Loki.

### 3.1 Cấu hình Promtail

```yaml
# promtail-config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/log/positions.yaml
  # Lưu vị trí đọc log — restart không đọc lại từ đầu

clients:
  - url: http://loki.monitoring:3100/loki/api/v1/push
    tenant_id: ""
    batchwait: 1s
    batch_size: 1024 * 1024

scrape_configs:
  # ─── Kubernetes Pods ───
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    pipeline_stages:
      - json:
          expressions:
            timestamp: timestamp
            level: level
            message: message
            trace_id: trace_id
            service: service
      - labels:
          level:
          service:
          namespace:
          pod:
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
      - source_labels: [__meta_kubernetes_namespace_name]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - action: replace
        replacement: /var/log/pods/$1/*.log
        source_labels: [__meta_kubernetes_pod_container_name]
        target_label: __path__

  # ─── systemd logs ───
  - job_name: systemd-journal
    journal:
      max_age: 12h
      labels:
        job: systemd-journal
    relabel_configs:
      - source_labels: [__journal__systemd_unit]
        target_label: unit

  # ─── Static file logs ───
  - job_name: nginx-access-logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: nginx-access
          env: production
        paths:
          - /var/log/nginx/access.log
    pipeline_stages:
      - regex:
          expression: '^(?P<ip>\S+) - (?P<user>\S+) \[(?P<timestamp>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) (?P<status>\d+) (?P<bytes>\S+)'
      - labels:
          method:
          path:
          status:
```

---

## 4. LogQL — Loki Query Language

### 4.1 Log Query (log selectors)

```logql
-- Cú pháp cơ bản
{label="value"}

-- Tất cả logs từ order-service
{service="order-service"}

-- Logs theo namespace
{service="order-service", namespace="production"}

-- Logs theo nhiều labels
{service=~"order|payment.*", namespace="production", level=~"error|warn"}
```

### 4.2 Filtering

```logql
-- Filter theo nội dung (literal)
{service="order-service"} |= "payment failed"

-- Filter không chứa (negation)
{service="order-service"} != "healthy"

-- Regex filter
{service="order-service"} |~ "error|timeout|failed"

-- Regex negation
{service="order-service"} !~ "INFO|DEBUG"

-- Kết hợp nhiều filter
{service="order-service"} |= "processing" |~ "order.*" |~ "timeout|error" != "retry"
```

### 4.3 Parsing

```logql
-- Parse JSON log
{service="order-service"} | json | level="error"

-- Parse JSON, trích xuất nhiều fields
{service="order-service"} | json | message, level, trace_id, user_id

-- Parse logfmt (key=value pairs)
{service="order-service"} | logfmt | level="error" | duration > 5s

-- Pattern parser (regex-like với named groups)
{service="order-service"} | pattern `<ip> - <user> <_> "<method> <path> <status>" <size>`

-- Parse regex capture groups
{service="order-service"} | regexp `(?P<ip>\S+) - (?P<user>\S+) \[(?P<ts>[^\]]+)\]`
```

### 4.4 Labels và Aggregation

```logql
-- Thêm derived label (tính toán từ log content)
{service="order-service"} | json | status_code >= 500 as long as status_code

-- Count logs by label
count_over_time({service="order-service"}[5m])

-- Rate (logs/giây)
rate({service="order-service"} | json | level="error"[5m])

-- Bytes per second
bytes_rate({service="order-service"}[5m])

-- Top N services by log volume
topk(5, sum by(service) (count_over_time({service=~".+"}[5m])))
```

### 4.5 Log queries thực tế

```logql
-- Tất cả ERROR logs từ payment-service
{service="payment-service", level="error"}

-- Logs chứa exception
{service="payment-service"} | json | message=~"exception|null.*pointer"

-- Logs có trace_id để correlate với trace
{service="payment-service"} | json | trace_id!=""

-- HTTP errors (4xx, 5xx)
{job="nginx-access"} | pattern `<ip> - <_> "<method> <path> <status>"` | status >= 400

-- Slow requests (>1s) từ access logs
{job="nginx-access"} | pattern `<ip> - <_> "<method> <path> <status>" <size>` | duration > 1s

-- Error rate từ logs (khi không có metrics)
sum(rate({service="payment-service"} |= "error"[5m])) / sum(rate({service="payment-service"}[5m]))

-- Tìm logs theo trace_id (Loki → Tempo correlation)
{service="payment-service"} | json | trace_id="4bf92f3577b34da6"

-- Error logs per minute, per service
sum by(service) (rate({service=~".+"} |= "error"[5m])) * 60
```

---

## 5. Loki Recording Rules & Alerting

### 5.1 Recording Rules (Log-based metrics)

```yaml
# /etc/loki/rules/fake.yml
groups:
  - name: log_queries
    rules:
      # Đếm error logs theo service
      - record: log_error_rate:5m
        expr: |
          sum by(service) (
            rate(
              {service=~".+"} | json | level="error" [5m]
            )
          )

      # Error rate từ logs
      - record: log_error_ratio:5m
        expr: |
          sum by(service) (
            rate({service=~".+"} | json | level="error" [5m])
          )
          /
          sum by(service) (
            rate({service=~".+"}[5m])
          )

      # Bytes ingested per service
      - record: log_ingestion_rate:5m
        expr: |
          sum by(service) (
            bytes_rate({service=~".+"}[5m])
          )
```

### 5.2 Log-based Alerts

```yaml
# Alert khi error rate cao (tính từ logs)
- alert: HighLogErrorRate
  expr: |
    sum by(service) (
      rate({service=~".+"} | json | level="error" [5m])
    )
    /
    sum by(service) (
      rate({service=~".+"}[5m])
    ) > 0.05
  for: 5m
  annotations:
    summary: "Log-based error rate > 5% on {{ $labels.service }}"
    description: "Error logs: {{ $value | printf '%.2f' }}%"
  labels:
    severity: warning
    source: log
```

---

## Tổng kết cú pháp LogQL

| Mục đích | Cú pháp LogQL |
|---|---|
| Tất cả logs service | `{service="my-app"}` |
| Filter literal | `\|= "error"` |
| Filter regex | `\|~ "error\|timeout"` |
| Parse JSON | `\| json \| field="value"` |
| Parse logfmt | `\| logfmt \| level="error"` |
| Parse pattern | `\| pattern \`<ip> - <user>\`` |
| Count over time | `count_over_time({...}[5m])` |
| Rate logs/s | `rate({...} \| json [5m])` |
| Top N by volume | `topk(5, sum by(service) (count_over_time({...}[5m])))` |
| Derived label | `\| json \| status_code >= 500 as long` |
| Bytes rate | `bytes_rate({...}[5m])` |
| Error ratio | `rate(...\|= "error"[5m]) / rate(...[5m])` |
