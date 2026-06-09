# Prometheus — Bài tập thực hành

---

## Lab 1: Cài đặt kube-prometheus-stack bằng Helm

### Mục tiêu
Triển khai Prometheus Operator + Grafana + Alertmanager lên Kubernetes.

### Các bước

**Bước 1: Thêm Helm repo**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

**Bước 2: Tạo values file**

```yaml
# prometheus-values.yaml
prometheus:
  prometheusSpec:
    retention: 15d                    # Giữ data 15 ngày
    retentionSize: 50GB
    replicas: 2                        # HA mode
    replicaExternalURL: ""             # Để trống → dùng ingress
    ruleSelector:
      matchLabels:
        prometheus: rules
    serviceMonitorSelector:
      matchLabels:
        release: prometheus
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          resources:
            requests:
              storage: 100Gi

alertmanager:
  alertmanagerSpec:
    replicas: 2
    retention: 120h

grafana:
  enabled: true
  adminPassword: "Prometheus@123"
  persistence:
    enabled: true
    size: 10Gi
    storageClassName: gp3
  grafana.ini:
    server:
      domain: grafana.example.com
    smtp:
      enabled: false

# Disable default exporters (sẽ cài riêng nếu cần)
prometheus-node-exporter:
  enabled: true

prometheusOperator:
  admissionWebhooks:
    enabled: true
```

**Bước 3: Cài đặt**

```bash
kubectl create namespace monitoring
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prometheus-values.yaml \
  --wait
```

**Bước 4: Kiểm tra**

```bash
# Xem tất cả pods trong namespace monitoring
kubectl get pods -n monitoring

# Xem services
kubectl get svc -n monitoring
```

**Kết quả mong đợi:**

```
NAME                                                     READY   STATUS
alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2     Running
alertmanager-prometheus-kube-prometheus-alertmanager-1   2/2     Running
prometheus-grafana-6b8f9c7f9-8xr5h                       3/3     Running
prometheus-kube-prometheus-operator-7d8c9b7b8-4kq5p      1/1     Running
prometheus-kube-state-metrics-5c7fb7c5f9-x7v6m           1/1     Running
prometheus-prometheus-kube-prometheus-prometheus-0       2/2     Running
prometheus-prometheus-kube-prometheus-prometheus-1       2/2     Running
prometheus-prometheus-node-exporter-4x9f2                1/1     Running
```

**Bước 5: Truy cập Grafana**

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:3000
# Mở http://localhost:3000
# Username: admin
# Password: Prometheus@123
```

---

## Lab 2: Cấu hình ServiceMonitor và Recording Rules

### Mục tiêu
Tự động scrape metrics từ custom app bằng ServiceMonitor, viết recording rules.

### Các bước

**Bước 1: Tạo sample app với metrics endpoint**

```python
# app_with_metrics.py
from flask import Flask, jsonify
import random
import time
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from werkzeug.serving import make_server

app = Flask(__name__)

REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'path', 'status_code']
)

REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'Request latency',
    ['method', 'path'],
    buckets=[0.01, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0]
)

ORDER_COUNT = Counter(
    'orders_created_total',
    'Total orders created',
    ['status']
)

@app.route("/api/orders", methods=["POST"])
def create_order():
    start = time.time()
    try:
        amount = random.uniform(10, 5000)
        time.sleep(random.uniform(0.01, 0.2))  # simulate work
        REQUEST_COUNT.labels(method='POST', path='/api/orders', status_code='201').inc()
        ORDER_COUNT.labels(status='success').inc()
        duration = time.time() - start
        REQUEST_LATENCY.labels(method='POST', path='/api/orders').observe(duration)
        return jsonify({"status": "created", "amount": round(amount, 2)}), 201
    except Exception as e:
        REQUEST_COUNT.labels(method='POST', path='/api/orders', status_code='500').inc()
        ORDER_COUNT.labels(status='failed').inc()
        return jsonify({"error": str(e)}), 500

@app.route("/api/orders/<order_id>", methods=["GET"])
def get_order(order_id):
    start = time.time()
    REQUEST_COUNT.labels(method='GET', path='/api/orders/<id>', status_code='200').inc()
    time.sleep(random.uniform(0.005, 0.05))
    duration = time.time() - start
    REQUEST_LATENCY.labels(method='GET', path='/api/orders/<id>').observe(duration)
    return jsonify({"order_id": order_id, "status": "delivered"}), 200

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

```bash
pip install flask prometheus_client
```

**Bước 2: Deploy app lên Kubernetes**

```yaml
# app-deployment.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo

---
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: demo
  labels:
    app: order-service
    release: prometheus    # Quan trọng: label này match ServiceMonitor
spec:
  selector:
    app: order-service
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9090
      targetPort: 8080

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: demo
  labels:
    app: order-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: app
          image: <your-registry>/order-service:v1
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

```bash
kubectl apply -f app-deployment.yaml
```

**Bước 3: Tạo ServiceMonitor**

```yaml
# servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-service
  namespace: demo
  labels:
    release: prometheus    # Quan trọng: match với Prometheus CRD
spec:
  selector:
    matchLabels:
      app: order-service
  namespaceSelector:
    matchNames:
      - demo
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      relabelings:
        - source_labels: [__meta_kubernetes_pod_label_app]
          target_label: service
        - source_labels: [__meta_kubernetes_namespace]
          target_label: namespace
```

```bash
kubectl apply -f servicemonitor.yaml
```

**Bước 4: Verify Prometheus đang scrape app**

```bash
# Port-forward Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090

# Gõ query:
# http_requests_total
# → Thấy metrics với labels: method, path, status_code
```

**Bước 5: Tạo Recording Rules**

```yaml
# recording_rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: order-service-recording
  namespace: demo
  labels:
    prometheus: rules
    release: prometheus
spec:
  groups:
    - name: order_service_slo
      interval: 30s
      rules:
        - record: order_service:request_rate:5m
          expr: |
            sum(rate(http_requests_total{service="order-service"}[5m])) by (service)

        - record: order_service:availability:5m
          expr: |
            sum(rate(http_requests_total{service="order-service",status_code=~"2.."}[5m]))
            /
            sum(rate(http_requests_total{service="order-service"}[5m]))

        - record: order_service:p99_latency:5m
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{service="order-service"}[5m])) by (le)
            ) * 1000

        - record: order_service:error_rate:5m
          expr: |
            sum(rate(http_requests_total{service="order-service",status_code=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{service="order-service"}[5m]))

        - record: order_service:error_budget_consumed:5m
          expr: |
            (1 - order_service:availability:5m) / 0.001
          labels:
            slo: "99.9"
```

```bash
kubectl apply -f recording_rules.yaml
```

**Bước 6: Kiểm tra recording rules đã apply**

```bash
# Query trên Prometheus UI:
# order_service:availability:5m
# order_service:p99_latency:5m
# order_service:error_budget_consumed:5m
```

---

## Lab 3: Prometheus HA — Multiple replicas

### Mục tiêu
Cấu hình Prometheus HA với 2 replicas, sharding để tránh single point of failure.

### Các bước

**Bước 1: Enable HA mode**

```yaml
# prometheus-ha-values.yaml
prometheus:
  prometheusSpec:
    replicas: 2
    # Dùng thanosSidecar để replicate data
    thanos:
      version: v0.32.0
    retention: 15d
    replicas: 2
    # Sharding: mỗi replica scrape 50% targets
    replicaExternalLabelName: __replica__
    externalLabels:
      cluster: prod-us-east
      env: production
```

**Bước 2: Cấu hình Thanos (toàn cục view)**

```yaml
# thanos-sidecar-values.yaml
# Thanos Sidecar chạy cùng mỗi Prometheus replica
# Thanos Store cung cấp unified view qua tất cả replicas

# Thanos Querier / Query (global view)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thanos-querier
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: thanos-querier
  template:
    metadata:
      labels:
        app: thanos-querier
    spec:
      containers:
        - name: thanos
          image: quay.io/thanos/thanos:v0.32.0
          args:
            - query
            - --store=prometheus-prometheus-kube-prometheus-prometheus-0.monitoring.svc:10901
            - --store=prometheus-prometheus-kube-prometheus-prometheus-1.monitoring.svc:10901
            - --query.replica-label=__replica__
          ports:
            - containerPort: 10902
              name: grpc
            - containerPort: 10901
              name: http
```

---

## Lab 4: Blackbox Monitoring với Probe

### Mục tiêu
Monitor external endpoints (API bên ngoài cluster) bằng blackbox exporter.

### Các bước

**Bước 1: Cài blackbox-exporter**

```bash
helm install blackbox prometheus-community/prometheus-blackbox-exporter \
  -n monitoring \
  --set config.config.modules.http_2xx.probe_http_valid_status_codes="200-299"
```

**Bước 2: Tạo Probe CRD**

```yaml
# probe.yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: external-endpoints
  namespace: monitoring
spec:
  interval: 60s
  scrapeTimeout: 30s
  module: http_2xx
  prober:
    url: blackbox-prometheus-blackbox-exporter.monitoring:9115
  targets:
    staticConfig:
      static:
        - https://google.com
        - https://github.com
        - https://api.stripe.com
      labels:
        group: external
        module: http_2xx
```

```bash
kubectl apply -f probe.yaml
```

**Bước 3: Query kết quả**

```promql
# probe_success{group="external"}
# → 1 = success, 0 = failed

# probe_http_duration_seconds{group="external"}
# → HTTP response time
```

---

## Cleanup

```bash
helm uninstall prometheus -n monitoring
helm uninstall blackbox -n monitoring
kubectl delete ns demo
kubectl delete -f servicemonitor.yaml -f recording_rules.yaml -f probe.yaml
```
