# Loki — Bài tập thực hành

---

## Lab 1: Cài đặt Loki bằng Helm

### Mục tiêu
Triển khai Loki (single-binary mode) lên Kubernetes.

### Các bước

**Bước 1: Thêm Helm repo**

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

**Bước 2: Cài đặt Loki**

```yaml
# loki-values.yaml
loki:
  auth_enabled: false              # Không dùng authentication (internal cluster)
  commonConfig:
    replication_factor: 1
    storage:
      type: s3
      s3:
        endpoint: s3.amazonaws.com
        region: us-east-1
        bucketnames: loki-data
        s3forcepathstyle: false

  limits_config:
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    ingestion_rate_mb: 50
    ingestion_burst_size_mb: 25

  schema_config:
    configs:
      - from: "2024-01-01"
        store: boltdb-shipper
        object_store: s3
        schema: v11
        index:
          prefix: loki_index_
          period: 24h

minio:
  enabled: false                   # Dùng S3 thật, không cần MinIO

singleBinary:
  replicas: 2
  persistence:
    enabled: true
    size: 10Gi
    storageClassName: gp3

# Promtail (log agent)
promtail:
  enabled: true
  config:
    clients:
      - url: http://loki.monitoring:3100/loki/api/v1/push
    positions:
      filename: /run/promtail/positions.yaml
    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
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
```

```bash
helm install loki grafana/loki \
  -n monitoring \
  -f loki-values.yaml \
  --wait
```

**Bước 3: Verify Loki đang chạy**

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# Test Loki API
kubectl port-forward -n monitoring svc/loki 3100:3100
curl http://localhost:3100/ready
# Kết quả: ready

curl http://localhost:3100/loki/api/v1/label
# Kết quả: {"status":"success","data":[...labels...]}
```

---

## Lab 2: Structured Logging — Tạo logs chuẩn để Loki parse

### Mục tiêu
Viết app sinh logs theo chuẩn JSON, cấu hình Promtail parse đúng.

### Các bước

**Bước 1: Tạo app với structured logging**

```python
# structured_logging_app.py
import logging
import json
import sys
import random
import time
import uuid
from datetime import datetime

# Structured logger — mỗi log là một JSON object
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "level": record.levelname,
            "service": "order-service",
            "version": "1.0.0",
            "message": record.getMessage(),
            "logger": record.name,
            "trace_id": str(uuid.uuid4())[:16],  # 16-char trace ID
        }
        # Thêm extra fields nếu có
        if hasattr(record, "order_id"):
            log_obj["order_id"] = record.order_id
        if hasattr(record, "duration_ms"):
            log_obj["duration_ms"] = record.duration_ms
        if hasattr(record, "amount"):
            log_obj["amount"] = record.amount
        if hasattr(record, "status_code"):
            log_obj["status_code"] = record.status_code
        if hasattr(record, "error"):
            log_obj["error"] = record.error
        return json.dumps(log_obj)

# Setup logger
logger = logging.getLogger("order-service")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)

def log_info(msg, **kwargs):
    record = logger.makeRecord(
        logger.name, logging.INFO, __file__, 0, msg, None, None
    )
    for k, v in kwargs.items():
        setattr(record, k, v)
    logger.handle(record)

def log_error(msg, error=None, **kwargs):
    record = logger.makeRecord(
        logger.name, logging.ERROR, __file__, 0, msg, None, None
    )
    if error:
        record.error = str(error)
    for k, v in kwargs.items():
        setattr(record, k, v)
    logger.handle(record)

# Simulate app
for i in range(100):
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    amount = round(random.uniform(10, 5000), 2)
    duration_ms = round(random.uniform(5, 500), 2)
    status_code = 201

    if random.random() < 0.05:  # 5% errors
        status_code = random.choice([500, 502, 503])
        log_error(
            f"Order processing failed",
            order_id=order_id,
            amount=amount,
            duration_ms=duration_ms,
            status_code=status_code,
            error="payment_timeout" if random.random() < 0.5 else "inventory_unavailable"
        )
    else:
        log_info(
            f"Order created successfully",
            order_id=order_id,
            amount=amount,
            duration_ms=duration_ms,
            status_code=status_code,
        )

    time.sleep(random.uniform(0.1, 0.5))
```

```bash
python structured_logging_app.py | tee logs.jsonl
# Output: JSON log entries, mỗi dòng một JSON
# {"timestamp":"2024-...","level":"INFO","service":"order-service",...}
# {"timestamp":"2024-...","level":"ERROR","service":"order-service","error":"payment_timeout",...}
```

**Bước 2: Cấu hình Promtail parse JSON**

```yaml
# promtail-json-scrape.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: monitoring
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
    positions:
      filename: /run/promtail/positions.yaml
    clients:
      - url: http://loki.monitoring:3100/loki/api/v1/push

    scrape_configs:
      - job_name: json-logs
        static_configs:
          - targets:
              - localhost
            labels:
              job: json-logs
              app: order-service
            paths:
              - /var/log/order-service/*.log

      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          - json:
              expressions:
                timestamp: timestamp
                level: level
                message: message
                service: service
                trace_id: trace_id
                order_id: order_id
                duration_ms: duration_ms
                amount: amount
                status_code: status_code
                error: error
          - labels:
              level:
              service:
              app:
              namespace:
              pod:
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app
          - source_labels: [__meta_kubernetes_namespace_name]
            target_label: namespace
          - action: replace
            replacement: /var/log/pods/$1/*.log
            source_labels: [__meta_kubernetes_pod_container_name]
            target_label: __path__
```

**Bước 3: Query logs đã được parse trên Grafana**

```
Explore → Loki

{service="order-service", level="error"}
→ Xem tất cả ERROR logs

{service="order-service"} | json | error != ""
→ Chỉ logs có field "error"

{service="order-service"} | json | level="error" | amount > 1000
→ ERROR logs với amount > 1000

{service="order-service"} | json | status_code >= 500
→ Logs với HTTP error codes
```

---

## Lab 3: Log-based Metrics — Prometheus rules từ Loki

### Mục tiêu
Dùng Loki recording rules để tạo metrics từ logs, phục vụ alerting.

### Các bước

**Bước 1: Cấu hình Loki Ruler (alerting/provisioning)**

```yaml
# loki-ruler-values.yaml
loki:
  ruler:
    enable_api: true
    storage:
      type: s3
      s3:
        endpoint: s3.amazonaws.com
        bucketnames: loki-ruler
        region: us-east-1
    rule_path: /tmp/loki/rules
    alertmanager_url: http://alertmanager.monitoring:9093
    evaluation_interval: 30s
    delivery_interval: 1m
```

```bash
helm upgrade loki grafana/loki -n monitoring -f loki-ruler-values.yaml --wait
```

**Bước 2: Tạo Loki recording rules**

```yaml
# loki-alerting-rules.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-alerting-rules
  namespace: monitoring
data:
  rules.yaml: |
    groups:
      - name: log_based_alerts
        interval: 30s
        rules:
          # Đếm error logs theo service (metric từ log)
          - record: log_errors:5m
            expr: |
              sum by(service, level) (
                count_over_time(
                  {service=~".+"} | json | level="error" [5m]
                )
              )

          # Error rate từ logs
          - record: log_error_ratio:5m
            expr: |
              sum by(service) (
                rate(
                  {service=~".+"} | json | level="error" [5m]
                )
              )
              /
              sum by(service) (
                rate(
                  {service=~".+"}[5m]
                )
              )

          # Error rate với latency từ logs
          - record: log_slow_error_rate:5m
            expr: |
              sum by(service) (
                rate(
                  {service=~".+"} | json | level="error" [5m]
                )
              )
              /
              sum by(service) (
                rate(
                  {service=~".+"}[5m]
                )
              )

          # Alerts
          - alert: HighLogErrorRate
            expr: |
              sum by(service) (
                rate(
                  {service=~".+"} | json | level="error" [5m]
                )
              )
              /
              sum by(service) (
                rate(
                  {service=~".+"}[5m]
                )
              ) > 0.05
            for: 5m
            labels:
              severity: warning
              source: loki-logs
            annotations:
              summary: "Log-based error rate > 5% for {{ $labels.service }}"
              description: "Service: {{ $labels.service }}, Error rate: {{ $value | printf '%.2f' }}%"
```

```bash
kubectl apply -f loki-alerting-rules.yaml
```

**Bước 3: Query metrics từ Loki rules**

```
Prometheus UI (sau khi Prometheus scrape Loki ruler endpoint):

# log_errors:5m
# → Count errors by service (từ log)

# log_error_ratio:5m
# → Error ratio by service (từ log)
```

---

## Lab 4: Correlate Logs ↔ Traces ↔ Metrics trong Grafana

### Mục tiêu
Dùng Grafana Explore để đi từ log → trace → metrics.

### Các bước

**Bước 1: Cấu hình Loki → Tempo correlation**

```
Configuration → Data Sources → Loki → Settings

Derived Fields:
  Add derived field:
    Name: trace_id
    Regex: trace_id=([a-f0-9]+)
    URL: http://tempo:3100/trace/${__value}
    Datasource: Tempo

→ Save & Test
```

**Bước 2: Trace → Logs flow**

```
Grafana → Explore → Tempo

1. Chọn trace bất kỳ
2. Click vào span
3. Trong span details → "View logs" button
4. → Loki Explore mở với filter: {service="..."} |= "trace_id=<id>"
5. → Xem tất cả log entries liên quan đến trace đó
```

**Bước 3: Logs → Traces flow**

```
Grafana → Explore → Loki

1. Query: {service="order-service"} |= "error" | json | trace_id!=""
2. Click vào một log entry
3. Click "Open trace" button (nếu có field trace_id)
4. → Xem trace tương ứng với log entry
```

**Bước 4: Metrics → Logs flow (dashboard panel)**

```
Dashboard → Panel → Add override

1. Thêm panel mới kiểu "Time series"
2. Query: rate({service="order-service"} |= "error" [5m])
3. Panel options → "Open in Explore" button

→ Click "Open in Explore"
→ Loki Explore mở với query tương ứng
```

---

## Cleanup

```bash
helm uninstall loki -n monitoring
kubectl delete -f loki-alerting-rules.yaml
kubectl delete -f promtail-json-scrape.yaml
```
