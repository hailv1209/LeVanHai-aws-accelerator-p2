# Grafana — Bài tập thực hành

---

## Lab 1: Xây dựng SLO Dashboard hoàn chỉnh

### Mục tiêu
Tạo Grafana dashboard theo dõi SLO với các panels: availability, latency, error budget.

### Các bước

**Bước 1: Truy cập Grafana**

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:3000
# Mở http://localhost:3000
# Đăng nhập: admin / Prometheus@123
```

**Bước 2: Thêm Prometheus Data Source**

```
Configuration → Data Sources → Add data source → Prometheus

Settings:
  Name: Prometheus
  URL: http://prometheus-kube-prometheus-prometheus.monitoring:9090
  Access: Server (default)
  Scrape interval: 15s

→ Save & Test → ✅ Success
```

**Bước 3: Tạo Dashboard mới**

```
+ → Create → Dashboard → Add new panel

Dashboard Settings:
  Name: SLO Overview
  Refresh: 30s
  Time range: Last 6 hours
```

**Bước 4: Tạo các Panels**

**Panel 1 — Availability (Stat):**

```
Title: Availability — SLO 99.9%

Query (PromQL):
  (sum(rate(http_requests_total{status=~"2.."}[5m])) /
   sum(rate(http_requests_total[5m]))) * 100

Options:
  → Stat panel
  → Unit: Custom / percentunit (0-1) → Display: 99.9%
  → Decimals: 4
  → Thresholds:
      99.7 = red (below SLA)
      99.9 = green
  → Color: Background (value)
```

**Panel 2 — p99 Latency (Time Series):**

```
Title: p99 Latency — SLO <500ms

Query:
  histogram_quantile(0.99,
    sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
  ) * 1000

Options:
  → Time series
  → Unit: Miscellaneous / ms
  → Legend: {{ instance }}
  → Thresholds:
      300ms = yellow
      500ms = red
  → Graph style: Line, width 2
```

**Panel 3 — Error Budget (Gauge):**

```
Title: Error Budget Remaining

Query:
  1 - ((1 - (
    sum(rate(http_requests_total{status=~"2.."}[30d]))
    /
    sum(rate(http_requests_total[30d]))
  )) / 0.001)

Options:
  → Gauge panel
  → Min: 0, Max: 1 (display as percent)
  → Unit: percent (0-100)
  → Thresholds:
      0-10%: red
      10-50%: yellow
      50-100%: green
  → Show threshold markers: ON
  → Show threshold labels: ON
```

**Panel 4 — Error Budget Consumed (Time Series):**

```
Title: Error Budget Consumed %

Query:
  100 - (
    100 * (
      sum(rate(http_requests_total{status=~"2.."}[30d]))
      /
      sum(rate(http_requests_total[30d]))
    )
    /
    99.9
  )

Options:
  → Time series
  → Unit: percent (0-100)
  → Thresholds:
      0-50%: green
      50-80%: yellow
      80-100%: red
```

**Panel 5 — Error Rate by Status Code (Pie Chart):**

```
Title: Requests by Status Code

Query:
  sum(rate(http_requests_total[5m])) by (status_code)

Options:
  → Pie chart
  → Legend: Table
  → Values: Percent
```

**Panel 6 — Request Rate (Time Series):**

```
Title: Request Rate (RPS)

Query:
  sum(rate(http_requests_total[5m])) by (service)

Options:
  → Time series
  → Unit: reqps (requests per second)
  → Fill opacity: 20
```

**Bước 5: Thêm Variables cho Dashboard**

```
Dashboard Settings → Variables → Add variable

Variable 1:
  Name: service
  Type: Query
  Query: label_values(http_requests_total, service)
  Multi: true
  Include All: true

Variable 2:
  Name: slo_threshold
  Type: Constant
  Query: 99.9
  Hide: variable

→ Update queries để dùng $service
  Query: sum(rate(http_requests_total{service=~"$service",status=~"2.."}[5m])) ...
```

**Bước 6: Lưu Dashboard**

```
Save dashboard: SLO Overview
Folder: SLO Dashboards
```

---

## Lab 2: Explore Logs — Loki + Grafana

### Mục tiêu
Dùng Grafana Explore mode để query và phân tích logs từ Loki.

### Các bước

**Bước 1: Thêm Loki Data Source**

```
Configuration → Data Sources → Add → Loki

URL: http://loki.monitoring:3100
→ Save & Test
```

**Bước 2: Explore Mode — Query Logs**

```
Explore (biểu tượng la bàn) → Select Loki datasource

Query 1: Tất cả logs từ order-service
  {service="order-service"}

Query 2: Chỉ logs có "error"
  {service="order-service"} |= "error"

Query 3: Logs JSON parse
  {service="order-service"} | json | level="error"

Query 4: Logs với latency > 1s
  {service="order-service"} | pattern `<ip> - <_> "<method>` | latency > 1

Query 5: Logs theo thời gian
  {service="order-service"} | logfmt | level=~"error|warn"
```

**Bước 3: Correlate Logs ↔ Traces**

```
Explore → Loki

Query: {service="order-service"} | json | trace_id != ""
→ Click vào log entry
→ "Open in Tempo" (có Loki → Tempo integration)

→ Xem trace tương ứng với log entry đó
→ Trace hiển thị: root span + tất cả child spans
→ Click vào span → xem log entries trong span đó
```

---

## Lab 3: Grafana Alerting — Alert khi SLO bị vi phạm

### Mục tiêu
Tạo alert rules trong Grafana và cấu hình notification.

### Các bước

**Bước 1: Tạo Contact Point (Slack)**

```
Alerting → Contact points → Add contact point

Name: slack-platform-alerts
Type: Slack

Settings:
  URL: https://hooks.slack.com/services/TXXXXXX/BXXXXXX/xxxxxx
  Recipient: #alerts-platform
  Username: Grafana Alerts
  Icon emoji: :warning:

→ Test contact point (sẽ gửi test message lên Slack)
→ Save
```

**Bước 2: Tạo Notification Policy**

```
Alerting → Notification policies → Default policy

Contact point: slack-platform-alerts
Group by: alertname, service
Group wait: 30s
Group interval: 5m
Repeat interval: 4h
```

**Bước 3: Tạo Alert Rule cho Availability**

```
Alerting → Alert rules → Add alert rule

Step 1: Define query and conditions
  Query A:
    expr: (sum(rate(http_requests_total{status=~"5.."}[5m])) /
            sum(rate(http_requests_total[5m]))) > 0.001
    Options: Reduce to: Last
    Condition: A is above 0

  Preview: shows current value

Step 2: Configure alert evaluation
  Name: SLO Availability < 99.9%
  Folder: SLO Alerts
  Group: slo-alerts
  Evaluation interval: every 1m
  For: 5m

Step 3: Annotations
  Summary: "SLO Availability breached: {{ $values.A }}%"
  Description: "Current availability is {{ $values.A }}%, below 99.9% SLO target"
  Runbook: https://wiki.example.com/runbooks/availability-breach

Step 4: Labels
  severity: critical
  slo: availability
  team: platform

→ Save
```

**Bước 4: Tạo Alert cho Latency**

```
Alerting → Add alert rule

Query:
  expr: histogram_quantile(0.99,
           sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
         ) * 1000 > 500
  For: 5m

Labels:
  severity: warning
  slo: latency

Annotations:
  Summary: "p99 latency {{ $value }}ms exceeds SLO threshold of 500ms"
```

**Bước 5: Tạo Alert cho Error Budget Exhausted**

```
Alerting → Add alert rule

Query:
  expr: (1 - (
    sum(rate(http_requests_total{status=~"2.."}[30d]))
    /
    sum(rate(http_requests_total[30d]))
  )) / 0.001 * 100 > 80

For: 10m

Labels:
  severity: critical
  policy: error-budget

Annotations:
  Summary: "Error budget consumed >80%. Remaining: {{ $value }}%"
```

**Bước 6: Kiểm tra Alert đang hoạt động**

```bash
# Tạo errors để trigger alert
for i in {1..100}; do
  curl http://order-service/api/orders -X POST \
    -H "Content-Type: application/json" \
    -d '{"force_error": true}'
done

# Chờ 5 phút (evaluation interval + "for" duration)
# → Alert sẽ chuyển sang trạng thái "Firing"
# → Notification được gửi lên Slack
```

**Bước 7: Xem Alert State History**

```
Alerting → Alert rules → Click vào rule
→ History tab: xem lịch sử alert state transitions
→ "Pending" → "Firing" → "Resolved"
```

---

## Lab 4: Provisioning Dashboards bằng ConfigMap

### Mục tiêu
Quản lý dashboards như code, deploy bằng Kubernetes ConfigMap.

### Các bước

**Bước 1: Export Dashboard thành JSON**

```
Dashboard → Settings → JSON Model → Copy JSON
→ Paste vào file: slo-overview.json
```

**Bước 2: Tạo ConfigMap**

```bash
kubectl create configmap grafana-slo-dashboard \
  --from-file=slo-overview.json=./slo-overview.json \
  --dry-run=client -o yaml > grafana-dashboard-configmap.yaml

kubectl apply -f grafana-dashboard-configmap.yaml -n monitoring
```

**Bước 3: Label ConfigMap để Grafana tự nhận diện**

```yaml
# grafana-dashboard-configmap.yaml (manual)
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-slo-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"    # Label bắt buộc để Grafana nhận diện
data:
  slo-overview.json: |
    {
      "annotations": {...},
      "title": "SLO Overview",
      "panels": [...],
      ...
    }
```

```bash
kubectl apply -f grafana-dashboard-configmap.yaml -n monitoring
```

**Bước 4: Verify Dashboard được load**

```
Dashboards → Browse
→ Thấy "SLO Overview" trong danh sách
→ Dashboard được quản lý bằng provisioning (icon ⭐)
```

---

## Cleanup

```bash
kubectl delete -f grafana-dashboard-configmap.yaml -n monitoring
# Dashboards đã xóa sẽ không xuất hiện trong Grafana nữa
```
