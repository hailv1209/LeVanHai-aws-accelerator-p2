# Prometheus — Lý thuyết & Cú pháp

---

## 1. Prometheus là gì?

**Prometheus** là một open-source monitoring system và time-series database, hoạt động theo mô hình **pull-based** (pull model).

```
┌──────────────────────────────────────────────────────────────┐
│                    PULL-BASED MODEL                          │
│                                                              │
│   ┌──────────────┐          ┌──────────────────────────┐   │
│   │  Prometheus  │ ──────▶  │  Target: /metrics        │   │
│   │  Server      │  scrape  │  (App / Node Exporter /   │   │
│   │              │ ◀──────  │   Kubernetes API)        │   │
│   └──────────────┘  metrics └──────────────────────────┘   │
│         │                                                  │
│         │ TSDB                                             │
│         ▼                                                  │
│   ┌──────────────┐                                        │
│   │  Time Series │                                        │
│   │  Database    │                                        │
│   └──────────────┘                                        │
└──────────────────────────────────────────────────────────────┘
```

**Đặc điểm chính:**

- **Pull-based**: Prometheus chủ động scrape metrics từ targets
- **Multi-dimensional data model**: Metrics có labels (dimensions)
- **PromQL**: Ngôn ngữ truy vấn mạnh mẽ
- **No reliance on distributed storage**: Single server, local storage
- **Service discovery**: Tự động phát hiện targets (Kubernetes, DNS, Consul...)

---

## 2. Data Model — Metric Types

### 2.1 Metric Format

```
<metric_name>{<label_name>="<label_value>", ...}
<value> <timestamp>

Ví dụ:
http_requests_total{method="GET", path="/api/users", status="200"} 15432 1718000000
```

### 2.4 Loại Metrics

| Loại | Mô tả | Ví dụ |
|---|---|---|
| **Counter** | Giá trị CHỈ tăng, không bao giờ reset | `http_requests_total`, `errors_total` |
| **Gauge** | Giá trị có thể tăng hoặc giảm | `cpu_usage_percent`, `memory_bytes` |
| **Histogram** | Phân bố giá trị, chia buck | `request_duration_seconds` |
| **Summary** | Phân bố giá trị, tính percentile phía client | `request_latency_seconds` |

**Counter:**

```promql
# Giá trị chỉ tăng — dùng rate() để tính tốc độ tăng
http_requests_total{method="GET", status="200"}

# Tốc độ request trên giây
rate(http_requests_total[5m])

# Tổng request trong 1 giờ
increase(http_requests_total[1h])
```

**Gauge:**

```promql
# Giá trị hiện tại — có thể đọc trực tiếp
cpu_usage_percent{instance="server-1"}

# Đo change rate
delta(cpu_usage_percent{instance="server-1"}[5m])
```

**Histogram:**

```promql
# Các buckets được định nghĩa sẵn khi khai báo histogram
# Ví dụ: buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

http_request_duration_seconds_bucket{le="0.1"}     # ≤ 100ms
http_request_duration_seconds_bucket{le="0.5"}     # ≤ 500ms
http_request_duration_seconds_bucket{le="1"}       # ≤ 1s
http_request_duration_seconds_bucket{le="+Inf"}    # Tổng tất cả

# histogram_quantile: tính percentile từ histogram buckets
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
# → 95% requests có latency ≤ giá trị này
```

---

## 3. PromQL — Cú pháp chi tiết

### 3.1 Operators

```promql
-- Arithmetic operators
http_requests_total / 1000                    -- chia
sum(rate(http_requests_total[5m]))             -- tổng

-- Comparison operators
rate(errors_total[5m]) > 0                    -- lọc
histogram_quantile(0.99, ...) >= 500          -- so sánh với threshold

-- Logical/set operators
rate(success_total[5m]) / rate(total[5m])     -- tỷ lệ
```

### 3.2 Functions phổ biến

```promql
-- rate() — tính tốc độ tăng trên giây (thường dùng nhất)
rate(http_requests_total[5m])

-- increase() — tổng tăng trong khoảng thời gian
increase(http_requests_total[1h])

-- irate() — instantaneous rate (dùng cho spike detection)
irate(http_requests_total[5m])

-- histogram_quantile() — tính percentile từ histogram
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

-- label_replace() — thêm/sửa label
label_replace(up{job="kubernetes-nodes"}, "region", "us-east", "instance", "(.*)")

-- topk() / bottomk() — lấy top/bottom N
topk(5, sum(rate(errors_total[5m])) by (service))

-- count_values() — đếm giá trị trùng lặp
count_values("count", count by (user_id)(http_requests_total))

-- absent() — kiểm tra metric có tồn tại không
absent(up{job="my-job"})  -- trả về 1 nếu metric không tồn tại
```

### 3.3 Aggregation Operators

```promql
-- sum() — tổng
sum(rate(http_requests_total[5m]))

-- avg() — trung bình
avg(rate(http_requests_total[5m])) by (service)

-- min / max
min(rate(http_requests_total[5m])) by (service)
max(rate(http_requests_total[5m])) by (service)

-- stddev() / stdvar() — độ lệch chuẩn
stddev(http_request_duration_seconds) by (service)

-- group — đếm instances
group(rate(http_requests_total[5m])) by (service)

-- count — đếm series
count(rate(http_requests_total[5m])) by (job)
```

### 3.4 PromQL cho SLO Metrics — Các query thực tế

```promql
-- ─── AVAILABILITY SLO ───

-- Tỷ lệ request thành công (SLI availability)
sum(rate(http_requests_total{status=~"2.."}[5m]))
/
sum(rate(http_requests_total[5m]))
-- Kết quả: 0.9995 = 99.95%

-- Tỷ lệ lỗi (error rate)
sum(rate(http_requests_total{status=~"5.."}[5m]))
/
sum(rate(http_requests_total[5m]))

-- Error budget consumed
(1 - (
  sum(rate(http_requests_total{status=~"2.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
)) / 0.001
-- Kết quả: 0.52 = 52% error budget đã dùng (với SLO 99.9%)

-- ─── LATENCY SLO ───

-- p50 latency
histogram_quantile(0.50,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000  -- ms

-- p95 latency
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000

-- p99 latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000

-- SLO compliance: tỷ lệ request < 500ms
sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m]))
/
sum(rate(http_request_duration_seconds_count[5m]))
-- Kết quả: 0.987 = 98.7% requests < 500ms

-- ─── INFRASTRUCTURE ───

-- CPU usage percentage
100 * (
  1 - (
    avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
  )
)

-- Memory usage percentage
100 * (
  1 - (
    avg by(instance) (node_memory_MemAvailable_bytes)
    /
    avg by(instance) (node_memory_MemTotal_bytes)
  )
)

-- Pods not ready
kube_pod_status_ready{condition="true"} == 0

-- Pods restarting frequently (>5 lần trong 10 phút)
increase(kube_pod_container_status_restarts[10m]) > 5

-- PVC usage
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100

-- ─── BUSINESS METRICS ───

-- Orders per minute
sum(rate(orders_created_total[1m]))

-- Revenue per minute (nếu có metric payment_amount)
sum(rate(payment_amount_total[5m]))

-- Active users (sessions trong 5 phút)
count(count by (user_id) (rate(http_requests_total[5m])))
```

---

## 4. Prometheus Configuration

### 4.1 Scrape Config cơ bản

```yaml
# prometheus.yml
global:
  scrape_interval: 15s         # Tần suất scrape (mặc định)
  evaluation_interval: 15s     # Tần suất evaluate alert rules
  external_labels:              # Labels gắn vào tất cả metrics
    env: production
    region: us-east-1

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # ─── Prometheus self-monitoring ───
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # ─── Kubernetes Nodes (cần node-exporter) ───
  - job_name: 'kubernetes-nodes'
    kubernetes_sd_configs:
      - role: node
    relabel_configs:
      - target_label: instance
        replacement: '${1}:9100'
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token

  # ─── Kubernetes Pods ───
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Chỉ scrape pod có annotation prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      # Thay đổi port
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        target_label: __param_target_port
        regex: (.+)
      # Map pod name → instance label
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: instance

  # ─── Kubernetes Services ───
  - job_name: 'kubernetes-services'
    kubernetes_sd_configs:
      - role: service
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: my-app
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        target_label: service

  # ─── Static Config (cho app bên ngoài K8s) ───
  - job_name: 'external-api'
    static_configs:
      - targets: ['api-server:9090', 'worker-1:9090']
    metrics_path: /metrics
    scrape_interval: 30s
```

### 4.2 Recording Rules — Pre-compute expensive queries

Recording rules giúp pre-calculate các query phức tạp, giảm tải khi truy vấn.

```yaml
# /etc/prometheus/rules/recording_rules.yml
groups:
  - name: slo_availability
    interval: 30s
    rules:
      # Tính sẵn availability SLI (tránh tính lại nhiều lần)
      - record: slo:availability:ratio5m
        expr: |
          sum(rate(http_requests_total{status=~"2.."}[5m]))
          /
          sum(rate(http_requests_total[5m]))

      - record: slo:error_budget:consumed5m
        expr: |
          (1 - slo:availability:ratio5m) / 0.001  # SLO 99.9%

      - record: slo:latency:p995m
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
          ) * 1000

  - name: service_level
    interval: 30s
    rules:
      - record: service:request_rate:5m
        expr: |
          sum(rate(http_requests_total[5m])) by (service, method)

      - record: service:error_rate:5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
          /
          sum(rate(http_requests_total[5m])) by (service)

      - record: service:p99_latency:5m
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          ) * 1000
```

### 4.3 Alert Rules

```yaml
# /etc/prometheus/rules/alert_rules.yml
groups:
  - name: service_alerts
    interval: 30s
    rules:
      # Alert khi service down
      - alert: InstanceDown
        expr: up == 0
        for: 2m              # Phải down 2 phút mới alert
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Instance {{ $labels.instance }} down"
          description: "{{ $labels.job }} has been down for more than 2 minutes."

      # Alert khi error rate cao
      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum(rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate on {{ $labels.service }}"
          description: "Error rate is {{ $value | printf '%.2f' }}%"

      # Alert khi latency cao
      - alert: HighLatency
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
          ) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "p99 latency > 2s on {{ $labels.service }}"
```

---

## 5. Prometheus Operator

**Prometheus Operator** tự động quản lý Prometheus instances bằng CRD thay vì config file.

### CRD chính

| CRD | Mô tả |
|---|---|
| `Prometheus` | Khai báo Prometheus instance muốn tạo |
| `ServiceMonitor` | Khai báo targets cần scrape (thay scrape config) |
| `PodMonitor` | Khai báo Pods cần scrape |
| `Probe` | Khai báo targets dùng blackbox exporter |
| `PrometheusRule` | Khai báo recording/alert rules |
| `AlertmanagerConfig` | Cấu hình alert routing |

### ServiceMonitor ví dụ

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app-monitor
  labels:
    release: prometheus    # Quan trọng: label này chọn Prometheus
spec:
  selector:
    matchLabels:
      app: my-app          # Match Service có label app=my-app
  namespaceSelector:
    matchNames:
      - default
      - monitoring
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      relabelings:
        - source_labels: [__meta_kubernetes_endpoint_node_name]
          target_label: node
```

### Prometheus CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
spec:
  replicas: 2               # HA mode
  retention: 15d
  retentionSize: 50GB
  serviceAccountName: prometheus
  serviceMonitorSelector:
    matchLabels:
      release: prometheus
  ruleSelector:
    matchLabels:
      prometheus: rules
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: alertmanager-main
        port: web
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: gp3
        resources:
          requests:
            storage: 100Gi
```

---

## Tổng kết cú pháp PromQL

| Mục đích | Cú pháp |
|---|---|
| Request rate/giây | `rate(metric_total[5m])` |
| Tổng tăng | `increase(metric_total[1h])` |
| Instantaneous rate | `irate(metric_total[5m])` |
| Percentile (p99) | `histogram_quantile(0.99, rate(bucket[5m]))` |
| Availability | `sum(rate(good_requests[5m])) / sum(rate(total_requests[5m]))` |
| Error rate | `sum(rate(errors[5m])) / sum(rate(total[5m]))` |
| Error budget | `(1 - availability) / (1 - SLO)` |
| Top N | `topk(5, rate(metric[5m]))` |
| Label replace | `label_replace(metric, "new_label", "value", "old_label", "regex")` |
| Pre-compute | Recording rule → `slo:availability:ratio5m` |
