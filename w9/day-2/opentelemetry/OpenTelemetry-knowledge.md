# OpenTelemetry — Lý thuyết & Kiến trúc

---

## 1. OpenTelemetry là gì?

**OpenTelemetry (OTel)** là một **vendor-neutral** observability framework, cung cấp spec và SDK chuẩn để thu thập telemetry data (traces, metrics, logs) và gửi đến bất kỳ backend nào (Prometheus, Jaeger, Loki, Datadog...).

```
┌──────────────────────────────────────────────────────────────┐
│                      BENEFITS                                │
├──────────────────────────────────────────────────────────────┤
│ ✅ Instrument code MỘT LẦN → gửi đến NHIỀU backend         │
│ ✅ Vendor-independent (không phụ thuộc Datadog/Splunk...)  │
│ ✅ CNCF project — được Google, Microsoft, Amazon hỗ trợ    │
│ ✅ Hỗ trợ: Traces, Metrics, Logs, Events, Baggage        │
│ ✅ Auto-instrumentation cho nhiều ngôn ngữ                 │
└──────────────────────────────────────────────────────────────┘
```

### So sánh trước và sau khi dùng OTel

```
TRƯỚC (vendor-specific):

  App Code ──────▶ Datadog SDK ──────▶ Datadog Agent
  App Code ──────▶ Jaeger Client ────▶ Jaeger Agent
  App Code ──────▶ Prometheus ──────▶ Prometheus Server

  → Muốn đổi backend = rewrite instrumentation

SAU (OTel):

  App Code ────▶ OTel SDK ────▶ OTel Collector ──┬──▶ Prometheus
                        │                        ├──▶ Jaeger
                        │                        ├──▶ Loki
                        │                        └──▶ Bất kỳ backend nào

  → Đổi backend = chỉ thay config Collector
```

---

## 2. Ba tín hiệu quan sát (Signals)

### 2.1 Traces — Theo dõi request đi qua hệ thống

```
Trace = toàn bộ hành trình của một request
Span  = một đơn vị công việc trong trace (function, HTTP call, DB query)

[Trace: order-service.process_order]
  [Span: validate_request]         ──────────────────▶ 50ms
    [Span: check_inventory]         ─────────────────▶ 120ms
    [Span: process_payment]         ─────────────────▶ 800ms
      [Span: stripe.charge]        ────────────────▶  750ms
    [Span: save_order]              ──────────────▶  30ms
      [Span: postgres.insert]       ───────────────▶  25ms
```

**Span Attributes:**

```python
span.set_attribute("order.id", "ORD-12345")
span.set_attribute("payment.amount", 99.99)
span.set_attribute("customer.tier", "premium")
span.set_attribute("http.method", "POST")
span.set_attribute("http.url", "https://api.example.com/pay")
span.set_attribute("http.status_code", 200)
```

**Span Events (log tại thời điểm cụ thể):**

```python
span.add_event("payment.received", {"amount": 99.99})
span.add_event("inventory.reserved", {"sku": "ABC-123"})
span.add_event("email.sent", {"template": "order_confirmation"})
```

**Span Links (span liên quan nhưng không phải parent-child):**

```python
# Khi xử lý message từ queue, link đến trace tạo ra message đó
context = Link(context=parent_span.context)
with tracer.start_as_current_span("process_message", links=[context]):
    ...
```

### 2.2 Metrics — Số liệu định lượng

**4 loại Metrics trong OTel:**

```
1. Counter      — Giá trị CHỈ TĂNG (request count, error count)
2. Histogram    — Phân bố giá trị (latency, payload size)
3. UpDownCounter — Tăng hoặc giảm (connection count, queue size)
4. Observable   — Giá trị được thu thập khi đọc (không chủ động record)
```

**Counter:**

```python
from opentelemetry import metrics

meter = metrics.get_meter(__name__)

request_counter = meter.create_counter(
    name="http_requests_total",
    description="Total HTTP requests",
    unit="1"
)

# Mỗi request gọi một lần
request_counter.add(1, {"method": "GET", "path": "/api/users"})
request_counter.add(1, {"method": "POST", "path": "/api/orders"})
```

**Histogram:**

```python
latency_histogram = meter.create_histogram(
    name="http_request_duration_seconds",
    description="HTTP request latency",
    unit="s"
)

# Quan sát latency
latency_histogram.record(
    0.523,  # seconds
    {"method": "GET", "path": "/api/users", "status_code": 200}
)
```

**UpDownCounter:**

```python
active_connections = meter.create_up_down_counter(
    name="db_connections_active",
    description="Active database connections",
    unit="1"
)

# Tăng/giảm theo connection lifecycle
active_connections.add(1)   # connection opened
active_connections.add(-1)  # connection closed
```

### 2.3 Logs — Bản ghi sự kiện

```
Log Record = {
  timestamp,
  severity (DEBUG/INFO/WARN/ERROR),
  body (message),
  attributes (key-value pairs),
  trace_id / span_id (để correlate với trace)
}

Ưu điểm OTel Logs:
  → Tự động attach trace_id/span_id vào log record
  → Không cần log manually trace ID nữa
  → Correlate log ↔ trace ↔ metrics dễ dàng
```

---

## 3. Kiến trúc OTel — Từ App đến Backend

```
┌─────────────────────────────────────────────────────────────────────┐
│                           APPLICATION LAYER                          │
│                                                                     │
│   Python / Go / Node.js / Java / Rust / .NET                        │
│   ┌──────────────────────────────────────────────────────┐          │
│   │  Manual Instrumentation         Auto Instrumentation   │          │
│   │  tracer.start_span()          Flask, FastAPI,       │          │
│   │  span.set_attribute()          gRPC, HTTP, DB...     │          │
│   │  meter.create_histogram()                              │          │
│   └────────────────────────────┬─────────────────────────┘          │
│                                │                                      │
│                    OTel SDK (per language)                          │
│                    (traces, metrics, logs)                          │
└───────────────────────────────┼─────────────────────────────────────┘
                                │ OTLP Protocol
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         OTel COLLECTOR                              │
│                                                                     │
│   Receivers          Processors              Exporters              │
│   ┌─────────┐        ┌──────────┐           ┌───────────┐          │
│   │  OTLP   │──▶     │  Batch   │──▶        │ Prometheus│          │
│   │  (gRPC) │        │  Memory  │            │ Loki      │          │
│   ├─────────┤        │  Limiter │            │ Jaeger    │          │
│   │  OTLP   │──▶     │  K8s Attr│──▶        │ Tempo     │          │
│   │  (HTTP) │        │  Transform│           │ Datadog   │          │
│   ├─────────┤        │  Filter   │           │ stdout    │          │
│   │  Jaeger │──▶     │  Resource │──▶        │ OTLP      │          │
│   │  Zipkin │        │  Detect   │           │ (another  │          │
│   ├─────────┤        └──────────┘            │  collector)│          │
│   │Prometheus│                                        └───────────┘          │
│   │ ( scrape)│                                                         │
│   └─────────┘                                                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. OTel SDK — Cú pháp theo ngôn ngữ

### 4.1 Python

```python
# Cài đặt
# pip install opentelemetry-api \
#             opentelemetry-sdk \
#             opentelemetry-exporter-otlp-proto-grpc \
#             opentelemetry-instrumentation-flask

from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

# ─── Resource ───
resource = Resource(attributes={
    SERVICE_NAME: "payment-service",
    "service.version": "2.1.0",
    "deployment.environment": "production",
    "cloud.region": "us-east-1"
})

# ─── Tracing ───
trace_provider = TracerProvider(resource=resource)
trace_exporter = OTLPSpanExporter(endpoint="http://otel-collector:4317")
trace_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
trace.set_tracer_provider(trace_provider)

# ─── Metrics ───
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint="http://otel-collector:4317"),
    export_interval_millis=60000  # export mỗi 60s
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

# ─── Sử dụng ───
tracer = trace.get_tracer(__name__)
meter = metrics.get_meter(__name__)

# Counter
payment_counter = meter.create_counter(
    name="payments.processed",
    description="Total payments processed"
)

# Histogram
payment_duration = meter.create_histogram(
    name="payment.duration_seconds",
    description="Payment processing duration"
)

@tracer.start_as_current_span("process_payment")
def process_payment(order_id: str, amount: float):
    current_span = trace.get_current_span()
    current_span.set_attribute("order.id", order_id)
    current_span.set_attribute("payment.amount", amount)

    try:
        with tracer.start_as_current_span("stripe.charge") as span:
            span.set_attribute("payment.method", "stripe")
            # ... gọi Stripe API ...
            payment_duration.record(0.750)
            payment_counter.add(1, {"status": "success"})

        current_span.set_status(trace.Status(trace.StatusCode.OK))
        return {"success": True}

    except Exception as e:
        current_span.record_exception(e)
        current_span.set_status(trace.Status(trace.StatusCode.ERROR, str(e)))
        payment_counter.add(1, {"status": "failed"})
        raise
```

### 4.2 Go

```go
// Cài đặt
// go get go.opentelemetry.io/otel \
//         go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc \
//         go.opentelemetry.io/otel/sdk/trace

package main

import (
    "context"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
)

func initTracer(ctx context.Context) (func(), error) {
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint("otel-collector:4317"),
        otlptracegrpc.WithInsecure(), // không TLS (dev/staging)
    )
    if err != nil {
        return nil, err
    }

    tp := trace.NewTracerProvider(
        trace.WithBatcher(exporter),
        trace.WithResource(resource.NewWithAttributes(
            semconv.ServiceName("order-service"),
            semconv.ServiceVersion("v1.0"),
            attribute.String("env", "production"),
        )),
    )

    otel.SetTracerProvider(tp)
    return func() { tp.Shutdown(context.Background()) }, nil
}

// Sử dụng trong handler
func CreateOrder(ctx context.Context, order Order) error {
    tracer := otel.Tracer("order-service")

    ctx, span := tracer.Start(ctx, "create_order")
    defer span.End()

    span.SetAttributes(
        attribute.String("order.id", order.ID),
        attribute.Float64("order.amount", order.Amount),
    )

    // Gọi database
    ctx, dbSpan := tracer.Start(ctx, "db.insert_order")
    err := db.Insert(ctx, order)
    dbSpan.End()

    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return err
    }

    span.SetStatus(codes.Ok, "")
    return nil
}
```

### 4.3 Node.js / TypeScript

```typescript
// Cài đặt
// npm install @opentelemetry/api \
//            @opentelemetry/sdk-node \
//            @opentelemetry/exporter-trace-otlp-grpc \
//            @opentelemetry/instrumentations \
//            @opentelemetry/sdk-metrics

// instrumentation.ts — phải import TRƯỚC app
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { Resource } from '@opentelemetry/resources';
import { SemanticResourceAttributes } from '@opentelemetry/semantic-conventions';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: 'user-service',
    [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
  }),
  traceExporter: new OTLPTraceExporter({
    url: 'http://otel-collector:4317',
  }),
  metricReader: /* ... */,
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': { enabled: true },
      '@opentelemetry/instrumentation-express': { enabled: true },
      '@opentelemetry/instrumentation-pg': { enabled: true },
    }),
  ],
});

sdk.start();
process.on('SIGTERM', () => sdk.shutdown());
```

---

## 5. OTel Collector — Cấu hình chi tiết

### 5.1 Pipeline cơ bản

```yaml
# otel-collector-config.yaml
receivers:
  # ─── OTLP (từ ứng dụng dùng OTel SDK) ───
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317    # mặc định cho OTel SDK
      http:
        endpoint: 0.0.0.0:4318    # alternative endpoint

  # ─── Prometheus (scrape metrics từ pod/app) ───
  prometheus:
    config:
      scrape_configs:
        - job_name: 'kubernetes-pods'
          kubernetes_sd_configs:
            - role: pod
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: 'true'

processors:
  # ─── Batch: gộp telemetry trước khi export (giảm network calls) ───
  batch:
    timeout: 1s
    send_batch_size: 1024  # gửi khi đủ 1024 spans/metrics

  # ─── Memory Limiter: tránh OOM khi spike ───
  memory_limiter:
    check_interval: 1s
    limit_mib: 512          # giới hạn memory
    spike_limit_mib: 128    # spike buffer

  # ─── K8s Attributes: thêm metadata từ Kubernetes ───
  k8sattributes:
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.deployment.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.pod.start_time
    pod_association:
      - from: resource_attribute
        source_labels: [k8s.pod.uid]

  # ─── Resource: set/update resource attributes ───
  resource:
    attributes:
      - action: upsert
        key: cloud.region
        value: "us-east-1"
      - action: upsert
        key: deployment.environment
        value: "production"

exporters:
  # ─── Prometheus (metrics endpoint để Prometheus scrape) ───
  prometheus:
    endpoint: "0.0.0.0:8889"
    namespace: "myapp"
    const_labels:
      env: production

  # ─── OTLP cho tracing (Tempo / Jaeger) ───
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

  # ─── Loki cho logs ───
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    labels:
      resource:
        service.name: service.name
        service.namespace: service.namespace
      record:
        - __name__

  # ─── Debug (stdout) cho development ───
  debug:
    verbosity: detailed      # detailed | normal | basic

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters: [otlp/tempo, debug]

    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheus, debug]

    logs:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters: [loki, debug]
```

### 5.2 Các Processor phổ biến

```yaml
processors:
  # Filter: loại bỏ telemetry không cần thiết
  transform:
    trace_statements:
      - context: span
        statements:
          - replace_pattern(attributes["http.url"], "^https://api-", "https://")
          - delete_key(attributes, "user.password")  # xóa sensitive data

  # Sampling: giảm volume cho production
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors-policy
        type: status_code
        status_code: {status_codes: [ERROR]}

      - name: slow-traces-policy
        type: latency
        latency: {threshold_ms: 1000}

      - name: probabilistic-policy
        type: probabilistic
        probabilistic: {sampling_percentage: 10}

  # Redaction: xóa PII/sensitive fields
  transform:
    log_statements:
      - context: log
        statements:
          - replace_pattern(body, "\\d{3}-\\d{2}-\\d{4}", "[SSN]")
          - replace_pattern(body, "password=[^&]+", "password=[REDACTED]")
```

---

## 6. Auto-Instrumentation — Không cần sửa code

### 6.1 Java

```bash
# Download Java agent
curl -O https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# Chạy app với agent tự động
java -javaagent:opentelemetry-javaagent.jar \
     -Dotel.service.name=my-app \
     -Dotel.exporter.otlp.endpoint=http://otel-collector:4317 \
     -Dotel.resource.attributes=deployment.environment=production \
     -jar my-app.jar
```

### 6.2 Python

```bash
pip install opentelemetry-instrumentation-flask \
             opentelemetry-instrumentation-requests \
             opentelemetry-instrumentation-sqlalchemy

# Chạy với auto-instrumentation
opentelemetry-instrument \
  --service-name my-flask-app \
  --exporter-otlp-endpoint http://collector:4317 \
  python app.py
```

### 6.3 Node.js

```bash
npm install @opentelemetry/auto-instrumentations-node

# app.mjs
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';

new NodeSDK({
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': {},
      '@opentelemetry/instrumentation-express': {},
      '@opentelemetry/instrumentation-pg': {},
    }),
  ],
}).start();

# Chạy
node --require ./instrumentation.mjs app.js
```

---

## 7. Baggage — Context propagation nâng cao

**Baggage** cho phép truyền metadata (key-value) qua toàn bộ trace, không chỉ riêng span.

```python
# Tại entry point (ví dụ: API gateway)
from opentelemetry import baggage

# Đặt baggage khi bắt đầu request
baggage.set_baggage("tenant.id", "customer-123")
baggage.set_baggage("user.tier", "premium")
baggage.set_baggage("feature.flags", "new-checkout=true,dark-mode=false")

# → Baggage sẽ tự động propagate qua tất cả spans trong trace
# → Không cần truyền thủ công qua mọi function call
```

```yaml
# Collector config để propagate baggage qua headers
processors:
  # Baggage được tự động đọc từ W3C Baggage header (hoặc propagate qua metadata)
  # Cần cấu hình propagator:
exporters:
  otlp:
    headers:
      # Baggage có thể được gửi qua header tùy propagator config
```

---

## Tổng kết

| Thành phần | Cú pháp / Khái niệm |
|---|---|
| **Trace** | `tracer.start_span(name)` → `span.set_attribute()` → `span.end()` |
| **Counter** | `counter.add(1, {"method": "GET"})` |
| **Histogram** | `histogram.record(0.523, {"path": "/api"})` |
| **UpDownCounter** | `counter.add(1)` / `counter.add(-1)` |
| **Collector Pipeline** | `receivers → processors → exporters` |
| **Auto-instrumentation** | `javaagent / opentelemetry-instrument / --require` |
| **Baggage** | `baggage.set_baggage(key, value)` → propagate toàn trace |
| **Propagators** | W3C TraceContext, W3C Baggage, B3 |
