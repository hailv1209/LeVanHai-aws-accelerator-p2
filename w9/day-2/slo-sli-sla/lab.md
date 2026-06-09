# SLO / SLI / SLA — Bài tập thực hành

---

## Lab 1: Tính Error Budget từ SLO

### Mục tiêu
Tính error budget cho các mức SLO khác nhau và hiểu ý nghĩa.

### Các bước

**Bước 1: Viết script tính Error Budget**

```python
# error_budget_calculator.py
import datetime

def calculate_error_budget(slo_percentage: float, period_days: int = 30):
    """
    Tính error budget từ SLO percentage.
    """
    total_minutes = period_days * 24 * 60
    error_budget_minutes = total_minutes * (1 - slo_percentage / 100)
    error_budget_hours = error_budget_minutes / 60
    error_budget_days = error_budget_hours / 24

    allowed_error_rate = (1 - slo_percentage / 100) * 100

    return {
        "slo_percentage": slo_percentage,
        "period_days": period_days,
        "total_minutes": total_minutes,
        "allowed_error_rate_pct": allowed_error_rate,
        "error_budget_minutes": round(error_budget_minutes, 2),
        "error_budget_hours": round(error_budget_hours, 2),
        "error_budget_days": round(error_budget_days, 4),
    }

# Tính cho nhiều mức SLO phổ biến
slo_levels = [99, 99.5, 99.9, 99.95, 99.99, 99.999]

print("=" * 70)
print(f"{'SLO':>8} | {'Allowed Error':>13} | {'Budget/min':>12} | {'Budget/hr':>10} | {'Budget/day':>10}")
print("-" * 70)

for slo in slo_levels:
    result = calculate_error_budget(slo)
    print(f"{slo:>7}% | {result['allowed_error_rate_pct']:>12.4f}% | "
          f"{result['error_budget_minutes']:>12.2f} | "
          f"{result['error_budget_hours']:>10.2f} | "
          f"{result['error_budget_days']:>10.4f}")

print("=" * 70)
```

**Chạy thử:**

```bash
python error_budget_calculator.py
```

**Kết quả mong đợi:**

```
SLO     | Allowed Error |   Budget/min |  Budget/hr |  Budget/day
----------------------------------------------------------------------
    99% |      1.0000%  |      432.00  |       7.20 |     0.3000
   99.5% |      0.5000%  |      216.00  |       3.60 |     0.1500
  99.9% |      0.1000%  |       43.20  |       0.72 |     0.0300
 99.95% |      0.0500%  |       21.60  |       0.36 |     0.0150
 99.99% |      0.0100%  |        4.32  |       0.07 |     0.0030
99.999% |      0.0010%  |        0.43  |       0.01 |     0.0003
```

---

## Lab 2: Giám sát Availability SLI bằng Prometheus

### Mục tiêu
Viết PromQL query để đo availability SLO từ metrics có sẵn.

### Yêu cầu tiênquả

- Kubernetes cluster đang chạy
- Prometheus đã cài (kube-prometheus-stack)
- Sample app có endpoint `/metrics`

### Các bước

**Bước 1: Tạo sample app để sinh metrics**

```python
# app_for_sli.py
from flask import Flask
import random
import time

app = Flask(__name__)

@app.route("/health")
def health():
    return {"status": "ok"}, 200

@app.route("/api/data")
def get_data():
    # 1% requests trả về 500 (giả lập lỗi)
    if random.random() < 0.01:
        return {"error": "internal"}, 500
    # 5% requests trả về 200 nhưng chậm (giả lập latency cao)
    if random.random() < 0.05:
        time.sleep(2)
    return {"data": "hello"}, 200

@app.route("/api/orders", methods=["POST"])
def create_order():
    if random.random() < 0.005:
        return {"error": "db timeout"}, 503
    return {"order_id": random.randint(1000, 9999)}, 201

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

```bash
pip install flask prometheus-client
python app_for_sli.py
```

**Bước 2: Cấu hình Prometheus scrape app này**

```yaml
# prometheus-slo-scrape.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: sli-demo-app
  labels:
    release: prometheus  # Quan trọng: phải match với ServiceMonitor selector
spec:
  selector:
    matchLabels:
      app: sli-demo-app
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
---
apiVersion: v1
kind: Service
metadata:
  name: sli-demo-app
  labels:
    app: sli-demo-app
spec:
  selector:
    app: sli-demo-app
  ports:
    - name: http
      port: 8080
    - name: metrics
      port: 9090
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sli-demo-app
  labels:
    app: sli-demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sli-demo-app
  template:
    metadata:
      labels:
        app: sli-demo-app
    spec:
      containers:
        - name: app
          image: <your-registry>/sli-demo-app:v1
          ports:
            - containerPort: 8080
            - containerPort: 9090
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

```bash
kubectl apply -f prometheus-slo-scrape.yaml -n monitoring
```

**Bước 3: Truy vấn Availability SLI trên Prometheus UI**

Mở Prometheus UI (port-forward):

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090
```

Gõ các query sau:

```
# 1. Availability tổng thể (SLO 99.9%)
(sum(rate(http_server_requests_seconds_count{status=~"2.."}[5m]))
 /
 sum(rate(http_server_requests_seconds_count[5m]))) * 100

# Kết quả: ~99% (vì app có 1% lỗi 500)
# Nếu < 99.9% → Error Budget đang được tiêu thụ
```

```
# 2. Availability theo từng endpoint
(sum(rate(http_server_requests_seconds_count{status=~"2.."}[5m])) by (uri)
 /
 sum(rate(http_server_requests_seconds_count[5m])) by (uri)) * 100
```

```
# 3. Error rate theo status code
sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) by (status)
 /
 sum(rate(http_server_requests_seconds_count[5m])) by (status)
```

```
# 4. Request rate per second
sum(rate(http_server_requests_seconds_count[5m])) by (uri)
```

---

## Lab 3: Giám sát Latency SLI bằng Histogram

### Mục tiêu
Dùng Prometheus histogram để đo p50/p95/p99 latency và đánh giá SLO.

### Các bước

**Bước 1: Thêm histogram metrics vào app**

```python
from prometheus_client import Histogram, generate_latest, CONTENT_TYPE_LATEST
from flask import Flask, Response

# Định nghĩa histogram buckets phù hợp với SLO
# Bucket boundaries: 50ms, 100ms, 200ms, 500ms, 1s, 2s
REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency in seconds',
    ['method', 'endpoint', 'status_code'],
    buckets=[0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0]
)

app = Flask(__name__)

@app.route("/api/data")
def get_data():
    import time
    start = time.time()

    # ... xử lý request ...

    duration = time.time() - start
    status = 200
    REQUEST_LATENCY.labels(
        method='GET',
        endpoint='/api/data',
        status_code=str(status)
    ).observe(duration)

    return {"data": "ok"}, status

@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

**Bước 2: PromQL cho Latency SLI**

Mở Prometheus → gõ:

```
# p50 latency (median)
histogram_quantile(0.50,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000
# → đơn vị: ms

# p95 latency
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000

# p99 latency (thường dùng cho SLO)
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000

# Latency SLO compliance: tỷ lệ requests < 500ms
(sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m]))
 /
 sum(rate(http_request_duration_seconds_count[5m]))) * 100

# Latency compliance multi-threshold
# Tỷ lệ requests đạt < 200ms
(sum(rate(http_request_duration_seconds_bucket{le="0.2"}[5m]))
 /
 sum(rate(http_request_duration_seconds_count[5m]))) * 100
```

---

## Lab 4: Xây dựng SLO Dashboard trên Grafana

### Mục tiêu
Tạo Grafana dashboard hiển thị Availability và Latency SLO + Error Budget.

### Các bước

**Bước 1: Tạo Grafana Dashboard JSON (import vào Grafana)**

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Mở http://localhost:3000 (default: admin/prom-operator)
```

**Bước 2: Thêm Prometheus datasource**

```
Settings → Connections → Data sources → Add data source → Prometheus
→ URL: http://prometheus-kube-prometheus-prometheus.monitoring:9090
→ Save & Test
```

**Bước 3: Tạo dashboard panels**

Tạo dashboard mới → Thêm panels:

```
Panel 1: "SLO Availability — 99.9%"
  Query:
    (sum(rate(http_server_requests_seconds_count{status=~"2.."}[5m]))
     /
     sum(rate(http_server_requests_seconds_count[5m]))) * 100

  Options:
    → Stat → Unit: percent (0-100)
    → Thresholds: 99.7=red, 99.9=yellow, 100=green (đảo ngược)
    → Color: Red if < 99.9

Panel 2: "p99 Latency (SLO: <500ms)"
  Query:
    histogram_quantile(0.99,
      sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
    ) * 1000

  Options:
    → Time series → Unit: ms
    → Legend: {{instance}}

Panel 3: "Error Budget Remaining"
  Query:
    100 - (
      (1 - (
        sum(rate(http_server_requests_seconds_count{status=~"2.."}[5m]))
        /
        sum(rate(http_server_requests_seconds_count[5m]))
      )) / 0.001
    ) * 100

  Options:
    → Gauge → Min: 0, Max: 100
    → Thresholds: 10=red, 50=yellow, 90=green
    → Unit: percent

Panel 4: "Error Budget Consumed (%)"
  Query:
    (
      (1 - (
        sum(rate(http_server_requests_seconds_count{status=~"2.."}[30d]))
        /
        sum(rate(http_server_requests_seconds_count[30d]))
      )) / 0.001
    ) * 100

  Options:
    → Stat → Unit: percent
    → Thresholds: 0=green, 50=yellow, 80=red, 100=dark red
```

**Bước 4: Tạo alert rule cho SLO breach**

```
Alerting → Alert rules → Create alert rule

Name: SLO Availability < 99.9%
Expr: (
        sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
        /
        sum(rate(http_server_requests_seconds_count[5m]))
      ) > 0.001

For: 5m
Labels: severity=critical, slo=availability
Annotations:
  summary: "SLO Availability breached! Current: {{ $value | printf '%.4f' }}"
```

---

## Lab 5: Tính Error Budget Consumed

### Mục tiêu
Theo dõi error budget đã tiêu thụ bao nhiêu phần trăm.

### Script Python tính budget consumed

```python
# slo_calculator.py
import requests
from datetime import datetime, timedelta

def query_prometheus(query: str, prometheus_url: str = "http://localhost:9090") -> float:
    """Query Prometheus và trả về giá trị đầu tiên."""
    response = requests.get(
        f"{prometheus_url}/api/v1/query",
        params={"query": query}
    )
    data = response.json()
    if data["status"] == "success" and data["data"]["result"]:
        return float(data["data"]["result"][0]["value"][1])
    return 0.0

def calculate_slo_status(slo_target: float, period_days: int = 30):
    """
    Tính toán SLO status và error budget consumed.
    """
    # Availability trong 30 ngày (rolling window)
    availability_query = (
        'sum(rate(http_server_requests_seconds_count{status=~"2.."}[30d])) '
        '/ sum(rate(http_server_requests_seconds_count[30d]))'
    )
    availability = query_prometheus(availability_query)

    # Tính error budget
    total_minutes = period_days * 24 * 60
    allowed_error_rate = 1 - slo_target / 100
    error_budget_minutes = total_minutes * allowed_error_rate

    # Error budget consumed
    actual_error_rate = 1 - availability
    error_budget_consumed_ratio = actual_error_rate / allowed_error_rate
    error_budget_consumed_pct = error_budget_consumed_ratio * 100

    # Tốc độ tiêu thụ budget (burn rate)
    # Ước tính: nếu tiếp tục như hiện tại, bao lâu hết budget
    current_budget = error_budget_minutes * (1 - error_budget_consumed_ratio)
    if actual_error_rate > 0:
        estimated_hours_to_exhaust = (
            current_budget / 60 / (actual_error_rate / allowed_error_rate)
        )
    else:
        estimated_hours_to_exhaust = float('inf')

    print("=" * 60)
    print(f"SLO Target:            {slo_target}%")
    print(f"Current Availability:  {availability * 100:.4f}%")
    print(f"Actual Error Rate:    {actual_error_rate * 100:.4f}%")
    print(f"Allowed Error Rate:   {allowed_error_rate * 100:.4f}%")
    print(f"Error Budget (30d):   {error_budget_minutes:.2f} phút")
    print(f"Budget Consumed:      {error_budget_consumed_pct:.2f}%")
    print(f"Budget Remaining:     {(100 - error_budget_consumed_pct):.2f}%")
    print(f"Est. time to exhaust: {estimated_hours_to_exhaust:.1f} giờ")
    print("=" * 60)

    # Policy check
    if error_budget_consumed_pct >= 100:
        print("🚨 STATUS: ERROR BUDGET EXHAUSTED — STOP DEPLOY!")
    elif error_budget_consumed_pct >= 80:
        print("⚠️  STATUS: ERROR BUDGET CRITICAL (>80%) — Reduce deploy velocity")
    elif error_budget_consumed_pct >= 50:
        print("⚠️  STATUS: WARNING (>50%) — Monitor closely")
    else:
        print("✅ STATUS: HEALTHY — Continue normal deploy velocity")
        print("✅ STATUS: OK — Reliability target met")

    return {
        "availability": availability,
        "error_budget_minutes": error_budget_minutes,
        "budget_consumed_pct": error_budget_consumed_pct,
    }

if __name__ == "__main__":
    # Với SLO 99.9%
    calculate_slo_status(slo_target=99.9, period_days=30)
```

---

## Tổng kết các bước thực hành

| Lab | Công cụ | Thời gian ước tính |
|---|---|---|
| 1. Tính Error Budget | Python script | 15 phút |
| 2. Availability SLI với Prometheus | Prometheus + ServiceMonitor | 30 phút |
| 3. Latency SLI với Histogram | Prometheus histogram | 20 phút |
| 4. Grafana SLO Dashboard | Grafana | 30 phút |
| 5. Error Budget Consumed | Python + Prometheus API | 20 phút |

---

## Cleanup

```bash
# Xóa resources sau khi hoàn thành
kubectl delete -f prometheus-slo-scrape.yaml -n monitoring
```
