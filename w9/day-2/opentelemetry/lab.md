# OpenTelemetry — Bài tập thực hành

---

## Lab 1: Cài đặt OTel Collector bằng Helm

### Mục tiêu
Triển khai OTel Collector lên Kubernetes bằng Helm chart, cấu hình pipeline cho traces + metrics + logs.

### Các bước

**Bước 1: Thêm Helm repo**

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

**Bước 2: Tạo config file**

```yaml
# otel-collector-values.yaml
mode: deployment                    # deployment / daemonset / daemonset+gateway

replicaCount: 2

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  processors:
    batch:
      timeout: 1s
      send_batch_size: 1024

    memory_limiter:
      check_interval: 1s
      limit_mib: 512
      spike_limit_mib: 128

    k8sattributes:
      extract:
        metadata:
          - k8s.namespace.name
          - k8s.deployment.name
          - k8s.pod.name

  exporters:
    prometheus:
      endpoint: "0.0.0.0:8889"
      const_labels:
        env: production

    otlp/tempo:
      endpoint: tempo:4317
      tls:
        insecure: true

    loki:
      endpoint: http://loki:3100/loki/api/v1/push

    logging:
      verbosity: detailed

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [otlp/tempo, logging]

      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheus, logging]

      logs:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [loki, logging]

# Khai báo ports để expose service
ports:
  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
  prometheus:
    enabled: true
    containerPort: 8889
    servicePort: 8889
```

**Bước 3: Cài đặt bằng Helm**

```bash
kubectl create namespace monitoring
helm install otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring \
  -f otel-collector-values.yaml \
  --wait
```

**Bước 4: Verify collector đang chạy**

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector

kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=50
```

**Kết quả mong đợi:**

```
NAME                                    READY   STATUS
otel-collector-0                        1/1     Running
otel-collector-1                        1/1     Running
```

---

## Lab 2: Instrument Python Flask app với OTel SDK

### Mục tiêu
Thêm manual instrumentation vào một Flask app: traces, metrics, logs.

### Các bước

**Bước 1: Tạo project**

```bash
mkdir otel-flask-demo && cd otel-flask-demo
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install flask \
            opentelemetry-api \
            opentelemetry-sdk \
            opentelemetry-exporter-otlp-proto-grpc \
            opentelemetry-instrumentation-flask \
            opentelemetry-instrumentation-requests
```

**Bước 2: Viết Flask app với OTel**

```python
# app.py
from flask import Flask, request, jsonify
import time
import random
import logging
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider, PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.sdk.trace.export import ConsoleSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.trace import Status, StatusCode

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ─── OTel Setup ───
def setup_otel():
    resource = Resource(attributes={
        SERVICE_NAME: "flask-order-service",
        "service.version": "1.0.0",
        "deployment.environment": "development"
    })

    # Tracing
    trace_provider = TracerProvider(resource=resource)

    # Dùng Console exporter cho dev (thay bằng OTLP exporter khi đã có collector)
    trace_provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(trace_provider)

    # Metrics
    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint="http://localhost:4317"),
        export_interval_millis=30000
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

setup_otel()

# ─── Custom Metrics ───
meter = metrics.get_meter(__name__)
request_counter = meter.create_counter(
    name="http_requests_total",
    description="Total HTTP requests"
)
latency_histogram = meter.create_histogram(
    name="http_request_duration_seconds",
    description="Request latency in seconds"
)
order_counter = meter.create_counter(
    name="orders_created_total",
    description="Total orders created"
)

# ─── Routes với Manual Instrumentation ───
tracer = trace.get_tracer(__name__)

@app.route("/api/orders", methods=["POST"])
def create_order():
    with tracer.start_as_current_span("create_order") as span:
        order_id = request.json.get("order_id", f"ORD-{random.randint(1000, 9999)}")
        amount = request.json.get("amount", 0)

        span.set_attribute("order.id", order_id)
        span.set_attribute("order.amount", amount)

        request_counter.add(1, {"method": "POST", "path": "/api/orders"})

        try:
            start = time.time()

            # Gọi inventory service (simulate)
            with tracer.start_as_current_span("check_inventory") as inv_span:
                inv_span.set_attribute("inventory.sku", f"SKU-{random.randint(1, 100)}")
                time.sleep(0.05)

            # Gọi payment service (simulate)
            with tracer.start_as_current_span("process_payment") as pay_span:
                pay_span.set_attribute("payment.method", "credit_card")
                if amount > 1000:
                    pay_span.set_attribute("payment.fraud_risk", "high")
                    # 5% chance of payment failure for high-value orders
                    if random.random() < 0.05:
                        pay_span.set_status(Status(StatusCode.ERROR, "Payment declined"))
                        span.set_status(Status(StatusCode.ERROR, "Payment failed"))
                        return jsonify({"error": "Payment failed"}), 402
                time.sleep(0.1)

            # Save order
            with tracer.start_as_current_span("db_save_order") as db_span:
                db_span.set_attribute("db.system", "postgresql")
                db_span.set_attribute("db.operation", "INSERT")
                time.sleep(0.03)

            duration = time.time() - start
            latency_histogram.record(
                duration,
                {"method": "POST", "path": "/api/orders", "status": "success"}
            )
            order_counter.add(1, {"status": "success"})

            span.set_status(Status(StatusCode.OK))
            logger.info(f"Order {order_id} created successfully")

            return jsonify({
                "order_id": order_id,
                "status": "created",
                "amount": amount
            }), 201

        except Exception as e:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
            order_counter.add(1, {"status": "failed"})
            return jsonify({"error": str(e)}), 500

@app.route("/api/orders/<order_id>", methods=["GET"])
def get_order(order_id):
    with tracer.start_as_current_span("get_order") as span:
        span.set_attribute("order.id", order_id)
        request_counter.add(1, {"method": "GET", "path": "/api/orders/<id>"})
        return jsonify({"order_id": order_id, "status": "shipped"}), 200

@app.route("/health")
def health():
    return {"status": "ok"}, 200

# ─── Auto-instrument Flask (HTTP middleware tự động) ───
FlaskInstrumentor().instrument_app(app)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
```

**Bước 3: Chạy app (development — không cần collector)**

```bash
# Development: dùng Console exporter để xem spans in terminal
python app.py
```

**Bước 4: Test endpoints**

```bash
# Tạo order thành công
curl -X POST http://localhost:8080/api/orders \
  -H "Content-Type: application/json" \
  -d '{"order_id": "ORD-100", "amount": 50}'

# Tạo order giá trị cao (có thể trigger payment failure)
curl -X POST http://localhost:8080/api/orders \
  -H "Content-Type: application/json" \
  -d '{"order_id": "ORD-200", "amount": 2000}'

# Get order
curl http://localhost:8080/api/orders/ORD-100

# Load test để sinh metrics
for i in {1..50}; do
  curl -s http://localhost:8080/api/orders/$i > /dev/null
done
```

**Bước 5: Xem output trên terminal**

```
Span: create_order
  Attributes: order.id=ORD-100, order.amount=50
  Child spans:
    check_inventory
    process_payment
    db_save_order

Span: get_order
  Attributes: order.id=ORD-100
```

---

## Lab 3: Kết nối OTel Collector với Python app

### Mục tiêu
Thay Console exporter bằng OTLP exporter, gửi telemetry đến OTel Collector.

### Các bước

**Bước 1: Sửa app.py — bật OTLP exporter (production)**

```python
# Thay thế phần setup_otel() trong app.py:

def setup_otel_production():
    resource = Resource(attributes={
        SERVICE_NAME: "flask-order-service",
        "service.version": "1.0.0",
        "deployment.environment": "production"
    })

    # Tracing — gửi đến OTel Collector
    trace_provider = TracerProvider(resource=resource)
    otlp_trace_exporter = OTLPSpanExporter(
        endpoint="http://otel-collector.monitoring:4317",
        insecure=True  # TLS không bật (dev/staging)
    )
    trace_provider.add_span_processor(BatchSpanProcessor(otlp_trace_exporter))
    trace.set_tracer_provider(trace_provider)

    # Metrics — gửi đến OTel Collector
    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(
            endpoint="http://otel-collector.monitoring:4317",
            insecure=True
        ),
        export_interval_millis=30000
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)
```

**Bước 2: Deploy app lên Kubernetes**

```yaml
# flask-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-order-service
  labels:
    app: flask-order-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flask-order-service
  template:
    metadata:
      labels:
        app: flask-order-service
    spec:
      containers:
        - name: app
          image: <your-registry>/flask-order-service:v1
          ports:
            - containerPort: 8080
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.monitoring:4317"
            - name: OTEL_SERVICE_NAME
              value: "flask-order-service"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "deployment.environment=production"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: flask-order-service
spec:
  selector:
    app: flask-order-service
  ports:
    - port: 80
      targetPort: 8080
```

```bash
kubectl apply -f flask-app.yaml -n default
```

**Bước 3: Verify spans đến Collector**

```bash
# Port-forward đến collector để xem metrics endpoint
kubectl port-forward -n monitoring svc/otel-collector-collector 8889:8889

# Kiểm tra Prometheus metrics endpoint
curl http://localhost:8889/metrics | grep "http_requests_total"

# Kết quả mong đợi:
# http_requests_total{method="POST",path="/api/orders",status="success"} 47
# http_requests_total{method="GET",path="/api/orders/<id>",status="success"} 3
```

---

## Lab 4: Auto-instrumentation Node.js app

### Mục tiêu
Instrument một Express.js app với OTel auto-instrumentation (không cần sửa code).

### Các bước

**Bước 1: Tạo project**

```bash
mkdir otel-node-demo && cd otel-node-demo
npm init -y
npm install express @opentelemetry/api \
             @opentelemetry/sdk-node \
             @opentelemetry/exporter-trace-otlp-grpc \
             @opentelemetry/instrumentation-express \
             @opentelemetry/instrumentation-http \
             @opentelemetry/instrumentation-pg
```

**Bước 2: Tạo instrumentation setup**

```javascript
// instrumentation.js — import TRƯỚC app.js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { getNodeAutoInstrumentations } = require('@opentelemetry/instrumentation-http');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: 'node-user-service',
    [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
  }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4317',
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingRequestHook: (req) => req.url === '/health',
      },
      '@opentelemetry/instrumentation-express': {
        enabled: true,
      },
      '@opentelemetry/instrumentation-pg': {
        enhancedDatabaseReporting: true,  // thêm SQL query vào span
      },
    }),
  ],
});

sdk.start();
console.log('✅ OTel auto-instrumentation started');

process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('OTel SDK shut down'))
    .catch((err) => console.error('Error shutting down OTel SDK', err));
});
```

**Bước 3: Viết Express app**

```javascript
// app.js
const express = require('express');
const { trace } = require('@opentelemetry/api');

const app = express();
const tracer = trace.getTracer('node-user-service');

app.use(express.json());

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/api/users/:id', async (req, res) => {
  const span = trace.getActiveSpan();
  const userId = req.params.id;
  span.setAttribute('user.id', userId);

  // Simulate DB call
  await new Promise(resolve => setTimeout(resolve, 50));

  span.setAttribute('user.found', true);
  res.json({ id: userId, name: 'Le Van Hai', email: 'hai@example.com' });
});

app.post('/api/users', async (req, res) => {
  const span = trace.getActiveSpan();
  const { name, email } = req.body;

  span.setAttribute('user.name', name);
  span.setAttribute('user.email', email);

  try {
    // Simulate database insert
    await new Promise(resolve => setTimeout(resolve, 30));
    span.setStatus({ code: 0 }); // OK
    res.status(201).json({ id: Math.floor(Math.random() * 1000), name, email });
  } catch (err) {
    span.recordException(err);
    span.setStatus({ code: 2, message: err.message }); // ERROR
    res.status(500).json({ error: 'Failed to create user' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 Server running on port ${PORT}`);
});
```

**Bước 4: Chạy với auto-instrumentation**

```bash
# Linux/macOS
node -r ./instrumentation.js app.js

# Windows
node --require ./instrumentation.js app.js
```

**Bước 5: Test**

```bash
curl http://localhost:3000/health
curl http://localhost:3000/api/users/123
curl -X POST http://localhost:3000/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Test User", "email": "test@example.com"}'
```

---

## Lab 5: Xây dựng OTel Collector pipeline với sampling

### Mục tiêu
Cấu hình Collector với tail-based sampling để giảm chi phí lưu trữ.

### Các bước

**Bước 1: Cập nhật Collector config với sampling**

```yaml
# otel-collector-sampling-values.yaml
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  processors:
    # ─── Tail-based Sampling ───
    # Quyết định sample SAU KHI span hoàn thành (khác với head-based)
    tail_sampling:
      decision_wait: 10s           # Đợi 10s trước khi quyết định
      num_traces: 50000            # Số traces giữ trong memory
      expected_new_traces_per_sec: 1000
      policies:
        # 1. Luôn giữ lại ERROR traces
        - name: errors-policy
          type: status_code
          status_code: {status_codes: [ERROR]}

        # 2. Giữ traces chậm (>1s)
        - name: slow-traces-policy
          type: latency
          latency: {threshold_ms: 1000}

        # 3. Probabilistic sampling cho traces bình thường
        - name: probabilistic-policy
          type: probabilistic
          probabilistic: {sampling_percentage: 10}

        # 4. Giữ traces từ critical services
        - name: critical-services-policy
          type: attributes_filter
          attributes:
            - key: service.name
              value: (payment-service|inventory-service|order-service)
              action: keep

    batch:
      timeout: 1s
      send_batch_size: 512

    memory_limiter:
      check_interval: 1s
      limit_mib: 1024
      spike_limit_mib: 256

    k8sattributes:
      extract:
        metadata:
          - k8s.namespace.name
          - k8s.deployment.name
          - k8s.pod.name

  exporters:
    otlp/tempo:
      endpoint: tempo:4317
      tls:
        insecure: true

    prometheus:
      endpoint: "0.0.0.0:8889"

    logging:
      verbosity: basic

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, tail_sampling, batch]
        exporters: [otlp/tempo]

      metrics:
        receivers: [otlp]
        processors: [batch]
        exporters: [prometheus]

      logs:
        receivers: [otlp]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [logging]
```

**Bước 2: Upgrade Collector**

```bash
helm upgrade otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring \
  -f otel-collector-sampling-values.yaml \
  --reuse-values \
  --wait
```

**Bước 3: Verify sampling đang hoạt động**

```bash
# Kiểm tra logs collector
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=20

# Xem Prometheus metrics để xác nhận tail sampling
curl http://localhost:8889/metrics | grep "otelcol_processor"

# Quan sát:
# otelcol_processor_spans_sampled_total  → số spans đã sample
# otelcol_processor_spans_dropped_total  → số spans đã drop
```

---

## Cleanup

```bash
# Xóa Helm release
helm uninstall otel-collector -n monitoring

# Xóa Kubernetes resources
kubectl delete -f flask-app.yaml
kubectl delete ns monitoring

# Xóa demo projects
rm -rf otel-flask-demo otel-node-demo
```
