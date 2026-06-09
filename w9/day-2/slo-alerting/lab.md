# SLO Alerting — Bài tập thực hành

---

## Lab 1: Tính Burn Rate và Error Budget bằng Python

### Mục tiêu
Viết script để tính burn rate, error budget consumed, và ước tính thời gian hết budget.

### Các bước

**Bước 1: Viết script tính burn rate**

```python
# burn_rate_calculator.py
from datetime import datetime, timedelta

def calculate_burn_rate(
    slo_percentage: float,
    actual_availability: float,
    window_minutes: int = 5
) -> dict:
    """
    Tính burn rate cho một window cụ thể.
    """
    # Error rate cho phép (trên phút)
    allowed_error_rate = (1 - slo_percentage / 100)

    # Error rate thực tế
    actual_error_rate = (1 - actual_availability)

    # Burn rate tức thời
    burn_rate = actual_error_rate / allowed_error_rate

    # Window 30 ngày tính bằng phút
    window_30d_minutes = 30 * 24 * 60  # 43,200 phút

    # Burn rate trong window (điều chỉnh với 30 ngày)
    burn_rate_adjusted = burn_rate * (window_30d_minutes / window_minutes)

    # % budget tiêu thụ mỗi giờ
    budget_per_hour = (allowed_error_rate / window_30d_minutes) * 60  # error budget per hour
    actual_budget_per_hour = actual_error_rate / (window_minutes / 60)
    budget_consumed_per_hour_pct = (actual_budget_per_hour / budget_per_hour) if budget_per_hour > 0 else float('inf')

    # Ước tính giờ còn lại
    if actual_error_rate > 0 and burn_rate > 0:
        hours_to_exhaust = 1 / (budget_consumed_per_hour_pct / 100) if budget_consumed_per_hour_pct > 0 else float('inf')
    else:
        hours_to_exhaust = float('inf')

    return {
        "slo_percentage": slo_percentage,
        "actual_availability": actual_availability,
        "allowed_error_rate": allowed_error_rate,
        "actual_error_rate": actual_error_rate,
        "burn_rate": burn_rate,
        "burn_rate_adjusted": burn_rate_adjusted,
        "budget_consumed_per_hour_pct": budget_consumed_per_hour_pct,
        "hours_to_exhaust": hours_to_exhaust,
    }

def print_burn_analysis(result: dict):
    print("=" * 70)
    print(f"SLO Target:              {result['slo_percentage']}%")
    print(f"Actual Availability:     {result['actual_availability'] * 100:.4f}%")
    print(f"Allowed Error Rate:      {result['allowed_error_rate'] * 100:.5f}%")
    print(f"Actual Error Rate:       {result['actual_error_rate'] * 100:.5f}%")
    print()
    print(f"Burn Rate:               {result['burn_rate']:.2f}×")
    print(f"Adjusted Burn Rate:      {result['burn_rate_adjusted']:.2f}× (30-day window)")
    print(f"Budget/giờ:             {result['budget_consumed_per_hour_pct']:.2f}%")
    print(f"Ước tính hết budget:    {result['hours_to_exhaust']:.1f} giờ")
    print()

    # Severity
    if result['burn_rate'] > 14.4:
        print("🔴 SEVERITY: P0 CRITICAL — Fast burn detected!")
        print("   Action: Alert immediately, page on-call NOW")
    elif result['burn_rate'] > 6.48:
        print("🟡 SEVERITY: P1 WARNING — Medium/Slow burn detected")
        print("   Action: Investigate within 30 phút")
    elif result['burn_rate'] > 1:
        print("🟡 SEVERITY: P2 — Slow burn detected")
        print("   Action: Schedule investigation")
    else:
        print("🟢 STATUS: HEALTHY — Burn rate normal")

# Test cases
test_cases = [
    # (slo, actual_availability, window_minutes)
    (99.9, 99.0, 5),    # Fast burn: 10% errors trong 5 phút
    (99.9, 99.0, 30),   # Medium burn: 10% errors trong 30 phút
    (99.9, 99.5, 60),   # Slow burn: 5% errors trong 1 giờ
    (99.9, 99.9, 5),    # Healthy: đúng SLO
    (99.99, 99.9, 5),   # Critical: 99.9% actual vs 99.99% SLO
]

for slo, actual, window in test_cases:
    print(f"\n{'─' * 70}")
    print(f"Test: SLO={slo}%, Actual={actual}%, Window={window}m")
    result = calculate_burn_rate(slo, actual, window)
    print_burn_analysis(result)
```

**Chạy thử:**

```bash
python burn_rate_calculator.py
```

**Kết quả mong đợi:**

```
──────────────────────────────────────────────────────────────────
Test: SLO=99.9%, Actual=99.0%, Window=5m
SLO Target:              99.9%
Actual Availability:     99.0000%
Allowed Error Rate:      0.10000%
Actual Error Rate:       1.00000%

Burn Rate:               10.00×
Adjusted Burn Rate:      86400.00× (30-day window)
Budget/giờ:             720000.00%
Ước tính hết budget:    0.0 giờ

🔴 SEVERITY: P0 CRITICAL — Fast burn detected!
   Action: Alert immediately, page on-call NOW
```

---

## Lab 2: Triển khai Multi-window Burn Rate Alerts

### Mục tiêu
Deploy PrometheusRule với multi-window burn rate alerts lên Kubernetes.

### Các bước

**Bước 1: Tạo PrometheusRule với burn rate alerts**

```yaml
# slo-prometheusrule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-burn-rate-alerts
  namespace: monitoring
  labels:
    prometheus: rules
    release: prometheus
spec:
  groups:
    # ─── RECORDING RULES (pre-compute SLIs) ───
    - name: slo_recording_rules
      interval: 30s
      rules:
        # Availability SLI — 5 phút
        - record: slo:availability:ratio5m
          expr: |
            sum(rate(http_requests_total{status=~"2.."}[5m]))
            /
            sum(rate(http_requests_total[5m]))

        # Availability SLI — 30 phút
        - record: slo:availability:ratio30m
          expr: |
            sum(rate(http_requests_total{status=~"2.."}[30m]))
            /
            sum(rate(http_requests_total[30m]))

        # Availability SLI — 1 giờ
        - record: slo:availability:ratio1h
          expr: |
            sum(rate(http_requests_total{status=~"2.."}[1h]))
            /
            sum(rate(http_requests_total[1h]))

        # Error Budget Consumed — 30 ngày
        - record: slo:error_budget_consumed:30d
          expr: |
            (
              1 - (
                sum(rate(http_requests_total{status=~"2.."}[30d]))
                /
                sum(rate(http_requests_total[30d]))
              )
            )
            /
            (1 - 0.999)
          labels:
            slo_target: "99.9"

        # p99 Latency — 5 phút
        - record: slo:p99_latency:5m
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
            ) * 1000

    # ─── BURN RATE ALERTS ───
    - name: slo_burn_rate_alerts
      interval: 30s
      rules:
        # FAST BURN: 5 phút × 5 phút
        # Alert ngay khi error rate cao bất thường
        - alert: SLIBurningFast
          expr: |
            (
              1 - slo:availability:ratio5m
            )
            /
            (
              (1 - 0.999)
              /
              (24 * 60)
            )
            > 14.4
          for: 5m
          labels:
            severity: critical
            slo: availability
            burn_rate_window: 5m
          annotations:
            summary: |
              🚨 FAST BURN: {{ $value | printf "%.1f" }}× — {{ $labels.sloth }} service
            description: |
              Burn rate {{ $value | printf "%.1f" }}× trong cửa sổ 5 phút.
              Đang tiêu thụ 1% error budget trong ~1 giờ.
              ACTION: Alert on-call immediately!

        # MEDIUM BURN: 30 phút × 30 phút
        - alert: SLIBurningMedium
          expr: |
            (
              1 - slo:availability:ratio30m
            )
            /
            (
              (1 - 0.999)
              /
              (24 * 60)
            )
            > 6.48
          for: 5m
          labels:
            severity: warning
            slo: availability
            burn_rate_window: 30m
          annotations:
            summary: |
              🔴 MEDIUM BURN: {{ $value | printf "%.1f" }}× — {{ $labels.sloth }} service
            description: |
              Burn rate {{ $value | printf "%.1f" }}× trong cửa sổ 30 phút.
              Đang có persistent degradation.
              ACTION: Investigate within 30 minutes.

        # SLOW BURN: 1 giờ × 10 phút
        - alert: SLIBurningSlow
          expr: |
            (
              1 - slo:availability:ratio1h
            )
            /
            (
              (1 - 0.999)
              /
              (24 * 60)
            )
            > 6.48
          for: 10m
          labels:
            severity: warning
            slo: availability
            burn_rate_window: 1h
          annotations:
            summary: |
              🟡 SLOW BURN: {{ $value | printf "%.1f" }}× — {{ $labels.sloth }} service
            description: |
              Slow burn rate {{ $value | printf "%.1f" }}× trong cửa sổ 1 giờ.
              Degradation âm thầm — budget sẽ hết trong ~3 tuần.
              ACTION: Schedule investigation.

    # ─── ERROR BUDGET ALERTS ───
    - name: error_budget_alerts
      interval: 30s
      rules:
        # 10% budget consumed trong 1 giờ
        - alert: SLOBudget10pctConsumed1h
          expr: |
            (
              1 - slo:availability:ratio1h
            )
            /
            (1 - 0.999)
            * 100
            > 10
          for: 5m
          labels:
            severity: warning
            policy: error-budget
          annotations:
            summary: "10% error budget consumed in 1h for {{ $labels.sloth }}"

        # 50% budget consumed
        - alert: SLOBudgetHalfConsumed
          expr: slo:error_budget_consumed:30d > 0.5
          for: 0m
          labels:
            severity: warning
            policy: error-budget
          annotations:
            summary: "50% error budget consumed — reduce deploy velocity"
            description: |
              {{ $labels.sloth }} đã tiêu thụ {{ $value | printf "%.0f" }}% error budget trong 30 ngày.
              Khuyến nghị: Giảm tốc độ deploy.

        # 90% budget consumed — STOP DEPLOY
        - alert: SLOBudgetExhausted
          expr: slo:error_budget_consumed:30d > 0.9
          for: 0m
          labels:
            severity: critical
            policy: error-budget
          annotations:
            summary: "90% error budget consumed — STOP DEPLOY!"
            description: |
              {{ $labels.sloth }} đã tiêu thụ {{ $value | printf "%.0f" }}% error budget!
              Action: Ngừng deploy ngay lập tức.
              Ưu tiên: Reliability & Stability.
```

**Bước 2: Apply PrometheusRule**

```bash
kubectl apply -f slo-prometheusrule.yaml

# Verify đã apply
kubectl get prometheusrule -n monitoring
kubectl describe prometheusrule slo-burn-rate-alerts -n monitoring
```

**Bước 3: Verify alerts trên Prometheus UI**

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090
```

Truy cập http://localhost:9090 → Alerts:

```
✅ SLIBurningFast        (no rows matching)
✅ SLIBurningMedium      (no rows matching)
✅ SLOBudgetHalfConsumed (no rows matching)
```

---

## Lab 3: Simulate Burn Rate Alert — Tạo errors để trigger alerts

### Mục tiêu
Tạo errors trong sample app để trigger burn rate alerts thực tế.

### Các bước

**Bước 1: Chạy sample app (từ Lab 2 Prometheus)**

```bash
# Deploy sample app (đã làm ở Prometheus lab)
kubectl apply -f app-deployment.yaml
```

**Bước 2: Tạo burst errors để trigger Fast Burn Alert**

```bash
# Script tạo errors để trigger burn rate alert
# Fast burn threshold: 14.4× → tương đương error rate ~0.14%/phút trong 5 phút
# Tạo ~1% errors trong thời gian ngắn

for i in {1..500}; do
  curl -s http://order-service/api/orders -X POST \
    -H "Content-Type: application/json" \
    -d '{"force_error": true}' > /dev/null &

  # Spawn 5 concurrent requests
  for j in {1..5}; do
    curl -s http://order-service/api/orders -X POST \
      -H "Content-Type: application/json" \
      -d '{"order_id": "err-'$i'", "amount": 9999}' > /dev/null &

    # 1/5 requests = error (20% error rate)
    if [ $((i % 5)) -eq 0 ]; then
      curl -s http://order-service/api/orders -X POST \
        -H "Content-Type: application/json" \
        -d '{"trigger_error": true}' > /dev/null
    fi
  done
done
```

**Bước 3: Monitor Prometheus Alerts**

```bash
# Query burn rate trên Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090

# Query:
# slo:availability:ratio5m
# → Xem availability hiện tại

# slo:error_budget_consumed:30d
# → Xem error budget consumed

# alertname=SLIBurningFast
# → Kiểm tra alert state

# irate(http_requests_total{status=~"5.."}[5m]) / sum(irate(http_requests_total[5m]))
# → Xem current error rate
```

**Bước 4: Observe Alert state transition**

```bash
# Chờ 5 phút (evaluation interval + "for" duration)
# Alert sẽ chuyển: Pending → Firing

# Xem alert states
curl -s "http://localhost:9090/api/v1/alerts" | jq '.data.alerts[] | select(.labels.alertname == "SLIBurningFast")'

# Kết quả:
# {
#   "labels": {
#     "alertname": "SLIBurningFast",
#     "severity": "critical"
#   },
#   "state": "firing",
#   "activeAt": "2024-01-01T00:05:00Z",
#   "annotations": {
#     "summary": "🚨 FAST BURN: 45.2× — order-service"
#   }
# }
```

**Bước 5: Verify AlertManager gửi notification**

```bash
# Kiểm tra AlertManager
kubectl port-forward -n monitoring svc/alertmanager-main 9093

# Mở http://localhost:9093
# → Thấy alert đang firing
# → Kiểm tra Slack/email notification
```

---

## Lab 4: Error Budget Calculator Dashboard

### Mục tiêu
Tạo Grafana dashboard theo dõi error budget consumed + burn rate.

### Các bước

**Bước 1: Tạo Grafana Dashboard JSON**

```bash
# Tạo dashboard mới trên Grafana
# Dashboard Settings → JSON Model → Copy
# Paste vào file: slo-error-budget-dashboard.json
```

**Bước 2: Thêm các Panels sau:**

```
Panel 1: "Error Budget Remaining"
  Type: Gauge
  Query:
    100 - (slo:error_budget_consumed:30d * 100)
  Thresholds: 0-10-50-90-100 (đảo ngược: <10=red, >90=green)
  Unit: percent

Panel 2: "Error Budget Consumed % (30d)"
  Type: Time series
  Query:
    slo:error_budget_consumed:30d * 100
  Thresholds: 0=green, 50=yellow, 80=red, 100=dark red

Panel 3: "Current Burn Rate"
  Type: Stat
  Query:
    (
      (1 - slo:availability:ratio5m)
    )
    /
    (
      (1 - 0.999)
      /
      (24 * 60)
    )
  Thresholds: 1=green, 6.48=yellow, 14.4=red

Panel 4: "Budget Exhaustion Forecast"
  Type: Stat
  Query:
    24 / (
      (
        (1 - slo:availability:ratio5m)
      )
      /
      (
        (1 - 0.999)
        /
        (24 * 60)
      )
    )
  Unit: hours
  Thresholds: 168=green, 72=yellow, 24=red

Panel 5: "Availability SLI (5m/30m/1h)"
  Type: Time series
  Query:
    slo:availability:ratio5m * 100
    slo:availability:ratio30m * 100
    slo:availability:ratio1h * 100
  Legend: 5m / 30m / 1h
  Thresholds: 99.9% line
```

**Bước 3: Provision Dashboard**

```yaml
# slo-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-slo-budget-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  slo-error-budget.json: |
    {
      "title": "SLO Error Budget Monitor",
      "tags": ["slo", "error-budget"],
      "panels": [...],
      ...
    }
```

```bash
kubectl apply -f slo-dashboard-configmap.yaml -n monitoring
```

---

## Lab 5: Tích hợp PagerDuty cho Critical Alerts

### Mục tiêu
Khi burn rate alert firing, tự động page PagerDuty.

### Các bước

**Bước 1: Cấu hình AlertManager với PagerDuty**

```yaml
# alertmanager-config.yaml
global:
  resolve_timeout: 5m

route:
  receiver: pagerduty-critical
  group_by: ['alertname', 'severity', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Critical alerts → PagerDuty (page immediately)
    - match:
        severity: critical
      receiver: pagerduty-critical
      continue: true

    # Warning alerts → Slack
    - match:
        severity: warning
      receiver: slack-alerts

receivers:
  - name: pagerduty-critical
    pagerduty_configs:
      - service_key: "{{ .PagerDutyServiceKey }}"
        severity: critical
        event_action: trigger
        description: |
          {{ range .Alerts }}
          {{ .Labels.alertname }} - {{ .Labels.service }}
          {{ .Annotations.summary }}
          {{ end }}
        details:
          alert_count: "{{ .Alerts | len }}"
          firing_alerts: |
            {{ range .Alerts }}
            - {{ .Labels.alertname }}: {{ .Annotations.description }}
            {{ end }}

  - name: slack-alerts
    slack_configs:
      - api_url: "{{ .SlackWebhookURL }}"
        channel: "#alerts-platform"
        title: |
          {{ range .Alerts }}
          :warning: {{ .Labels.alertname }}
          {{ end }}
        text: |
          {{ range .Alerts }}
          *{{ .Labels.alertname }}*
          {{ .Annotations.summary }}
          Service: {{ .Labels.service }}
          {{ end }}
        send_resolved: true
```

**Bước 2: Apply AlertManager config**

```bash
kubectl create secret generic alertmanager-config \
  --from-literal=pagerduty_service_key="YOUR-PAGERDUTY-INTEGRATION-KEY" \
  --from-literal=slack_webhook_url="YOUR-SLACK-WEBHOOK-URL" \
  -n monitoring

kubectl create secret generic alertmanager-main-secret \
  --from-file=alertmanager.yaml=alertmanager-config.yaml \
  -n monitoring

helm upgrade alertmanager prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set alertmanager.configSecret=alertmanager-main-secret \
  --reuse-values
```

---

## Cleanup

```bash
kubectl delete -f slo-prometheusrule.yaml
kubectl delete -f slo-dashboard-configmap.yaml
kubectl delete -f app-deployment.yaml
```
