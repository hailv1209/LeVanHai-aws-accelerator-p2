# AnalysisTemplate — Lý thuyết & Cú pháp

---

## 1. AnalysisTemplate là gì?

**AnalysisTemplate** là Custom Resource Definition (CRD) của Argo Rollouts, định nghĩa **Prometheus queries** để tự động verify canary/blue-green trong quá trình rollout.

```
┌──────────────────────────────────────────────────────────────────┐
│                    ANALYSIS WORKFLOW                               │
│                                                                  │
│  Rollout bắt đầu (setWeight 10%)                               │
│       │                                                          │
│       ▼                                                          │
│  Argo Rollouts Controller                                        │
│       │                                                          │
│       ▼                                                          │
│  AnalysisTemplate (Prometheus query)                             │
│       │                                                          │
│       ▼                                                          │
│  ┌─────────────┐    ┌─────────────┐                           │
│  │ Prometheus  │───▶│  Result     │                           │
│  │ Query       │    │  ✅ Pass    │──▶ Tiếp tục promote     │
│  │             │    │  ❌ Fail   │──▶ Abort Rollout         │
│  └─────────────┘    └─────────────┘                           │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. AnalysisTemplate CRD — Cú pháp

### 2.1 Cấu trúc cơ bản

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-check
  namespace: default
spec:
  args:
    - name: service-name
      required: true

  metrics:
    - name: success-rate
      interval: 1m          # Tần suất chạy query
      count: 3              # Số lần retry nếu fail
      successCondition: result[0] >= 0.99  # Threshold để pass

      # Prometheus query
      prometheus:
        address: http://prometheus.monitoring:9090
        query: |
          sum(rate(http_requests_total{
            service='{{args.service-name}}',
            status=~"2.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_requests_total{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))
```

### 2.2 Các Metric Providers

```yaml
# Prometheus
metrics:
  - name: success-rate
    prometheus:
      address: http://prometheus:9090
      query: "..."

  # Datadog
  - name: error-rate
    datadog:
      apiVersion: v2
      queries:
        - key: error_rate
          query: "avg:http.server.errors{*}.as_rate()"
      interval: 1m
      successCondition: result[0] <= 0.01

  # Job (generic HTTP check)
  - name: http-check
    job:
      interval: 30s
      successCondition: result.code == 200
      failureLimit: 1
      provider:
        http:
          url: https://example.com/health
          timeout: 10s

  # Wavefront
  - name: latency-check
    wavefront:
      address: https://example.wavefront.com
      query: "ts(...)"
      successCondition: result[0] < 100
```

### 2.3 SuccessCondition & FailureCondition

```yaml
metrics:
  - name: availability
    prometheus:
      query: |
        sum(rate(http_requests_total{service='{{args.service-name}}'}[5m]))
        /
        sum(rate(http_requests_total{service='{{args.service-name}}'}[5m]))
    successCondition: result[0] >= 0.999    # >= 99.9%
    failureCondition: result[0] < 0.990      # < 99% → fail

  - name: error-rate
    prometheus:
      query: |
        sum(rate(http_requests_total{
          service='{{args.service-name}}',
          status=~"5.."
        }[5m]))
        /
        sum(rate(http_requests_total{
          service='{{args.service-name}}'
        }[5m]))
    successCondition: result[0] <= 0.001    # <= 0.1%
    failureCondition: result[0] > 0.005     # > 0.5% → fail

  - name: latency-p99
    prometheus:
      query: |
        histogram_quantile(0.99,
          sum(rate(http_request_duration_seconds_bucket{
            service='{{args.service-name}}'
          }[5m])) by (le)
        ) * 1000
    successCondition: result[0] < 500    # p99 < 500ms
    failureCondition: result[0] > 1000   # p99 > 1000ms → fail

  - name: success-rate-with-args
    prometheus:
      query: |
        sum(rate(http_requests_total{
          service='{{args.service-name}}',
          status=~"2.."
        }[{{metric.interval}}]))
        /
        sum(rate(http_requests_total{
          service='{{args.service-name}}'
        }[{{metric.interval}}]))
    successCondition: result[0] >= {{args.min-success-rate}}
    failureCondition: result[0] < {{args.min-success-rate}}
```

### 2.4 Interval, Count, và FailureLimit

```yaml
metrics:
  - name: reliability-check
    interval: 2m         # Chạy query mỗi 2 phút
    count: 5            # Tối đa 5 lần
    failureLimit: 2      # Fail sau 2 lần liên tiếp

    # Đợi 30s trước khi bắt đầu
    initialDelay: 30s

    prometheus:
      query: |
        sum(rate(http_requests_total{
          service='{{args.service-name}}'
        }[{{metric.interval}}]))

    successCondition: result[0] > 0

# Tổng thời gian analysis:
# initialDelay (30s) + interval × count (2m × 5 = 10m) = ~10.5 phút
```

---

## 3. Args — Truyền tham số

### 3.1 Built-in Args

Argo Rollouts tự động cung cấp một số args có sẵn:

```yaml
args:
  # Tên service canary (trỏ bởi canaryService)
  - name: service-name
    value: hello-canary

  # Namespace của rollout
  - name: namespace
    value: default

  # Tên rollout
  - name: rollout-name
    value: hello

  # Revision hiện tại
  - name: revision
    value: "2"
```

### 3.2 Custom Args

```yaml
args:
  - name: service-name
    value: hello-canary     # Giá trị mặc định

  - name: min-success-rate
    value: "0.999"          # 99.9%

  - name: max-latency-ms
    value: "500"            # 500ms

  - name: error-threshold
    value: "0.005"          # 0.5%

  - name: prometheus-url
    valueFrom:
      fieldRef:
        fieldPath: metadata.annotations['prometheus-url']
```

### 3.3 Args trong Rollout

```yaml
# Trong Rollout CRD, truyền args khi gọi AnalysisTemplate
strategy:
  canary:
    steps:
      - analysis:
          templates:
            - templateName: success-rate-check
          args:
            - name: service-name
              value: hello-canary
            - name: min-success-rate
              value: "0.999"
            - name: max-latency-ms
              value: "500"
```

---

## 4. ClusterAnalysisTemplate — Template dùng chung toàn cục

### 4.1 Cú pháp

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: slo-availability-check
spec:
  args:
    - name: service-name
    - name: min-success-rate
      value: "0.999"

  metrics:
    - name: success-rate
      prometheus:
        address: http://prometheus.monitoring:9090
        query: |
          sum(rate(http_requests_total{
            service='{{args.service-name}}',
            status=~"2.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_requests_total{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))
      successCondition: result[0] >= {{args.min-success-rate}}
```

### 4.2 Dùng ClusterAnalysisTemplate trong Rollout

```yaml
strategy:
  canary:
    analysis:
      templates:
        - templateName: slo-availability-check
          # Không cần ClusterAnalysisTemplate prefix
      args:
        - name: service-name
          value: my-app
```

---

## 5. Inline Analysis — Không cần AnalysisTemplate

```yaml
# Định nghĩa analysis trực tiếp trong Rollout
strategy:
  canary:
    steps:
      - analysis:
          templateName: inline-check
          args:
            - name: error-rate-threshold
              value: "0.01"

---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: inline-check
spec:
  args:
    - name: error-rate-threshold
  metrics:
    - name: error-check
      interval: 1m
      count: 3
      prometheus:
        address: http://prometheus.monitoring:9090
        query: |
          sum(rate(http_requests_total{
            status=~"5.."
          }[5m]))
          /
          sum(rate(http_requests_total[5m]))
      successCondition: result[0] <= {{args.error-rate-threshold}}
```

---

## 6. Multiple Metrics — AND/OR Logic

### 6.1 All metrics must pass (AND)

```yaml
# Tất cả metrics phải pass mới promote
metrics:
  - name: success-rate
    successCondition: result[0] >= 0.999

  - name: latency-p99
    successCondition: result[0] < 500

  - name: error-rate
    failureCondition: result[0] > 0.005

# → Nếu BẤT KỲ metric nào fail → rollout abort
```

### 6.2 Inconclusive handling

```yaml
metrics:
  - name: availability
    inconclusiveCondition: result[0] == -1   # Giá trị đặc biệt = inconclusive
    inconclusiveBehavior: Continue  # Hoặc Fail

  - name: latency
    inconclusiveCondition: result[0] == -1
    inconclusiveBehavior: Inconclusive  # Giữ nguyên trạng thái
```

---

## 7. Prometheus Query cho SLO Metrics

### 7.1 Availability / Success Rate

```promql
sum(rate(http_requests_total{
  service='{{args.service-name}}',
  status=~"2.."
}[{{metric.interval}}]))
/
sum(rate(http_requests_total{
  service='{{args.service-name}}'
}[{{metric.interval}}]))
```

### 7.2 Error Rate

```promql
sum(rate(http_requests_total{
  service='{{args.service-name}}',
  status=~"5.."
}[{{metric.interval}}]))
/
sum(rate(http_requests_total{
  service='{{args.service-name}}'
}[{{metric.interval}}]))
```

### 7.3 Latency p99

```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{
    service='{{args.service-name}}'
  }[{{metric.interval}}])) by (le)
) * 1000
```

### 7.4 Latency p95

```promql
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket{
    service='{{args.service-name}}'
  }[{{metric.interval}}])) by (le)
) * 1000
```

### 7.5 Burn Rate (SLO Alert Integration)

```promql
(
  (
    sum(rate(http_requests_total{
      service='{{args.service-name}}',
      status=~"5.."
    }[{{metric.interval}}]))
    /
    sum(rate(http_requests_total{
      service='{{args.service-name}}'
    }[{{metric.interval}}]))
  )
  /
  (
    (1 - 0.999)
    /
    (24 * 60)
  )
)
# → Burn rate > 14.4 = fast burn → abort
```

### 7.6 Custom Metrics (Redis, DB, etc.)

```promql
# Redis latency
redis_cmd_duration_seconds{service='{{args.service-name}}', cmd="GET", quantile="0.99"} * 1000

# Database query latency
pg_stat_activity_max_tx_duration{role="primary", service='{{args.service-name}}'}

# Custom business metric
payment_success_total{service='{{args.service-name}}'}

# Request rate drop
sum(rate(http_requests_total{
  service='{{args.service-name}}'
}[{{metric.interval}}]))
```

---

## 8. Integration với SLO Burn Rate Alerting

Khi kết hợp AnalysisTemplate với burn rate alerts, ta có thể abort rollout ngay khi phát hiện SLO degradation.

```yaml
# AnalysisTemplate dùng burn rate query
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: slo-burn-rate-check
spec:
  args:
    - name: service-name
    - name: slo-target
      value: "0.999"

  metrics:
    # Fast burn check (5 phút)
    - name: fast-burn
      interval: 1m
      count: 3
      prometheus:
        query: |
          (
            sum(rate(http_requests_total{
              service='{{args.service-name}}',
              status=~"5.."
            }[5m]))
            /
            sum(rate(http_requests_total{
              service='{{args.service-name}}'
            }[5m]))
          )
          /
          (
            (1 - {{args.slo-target}})
            /
            (24 * 60)
          )
      successCondition: result[0] < 14.4    # < 14.4× = healthy
      failureCondition: result[0] >= 14.4   # ≥ 14.4× = abort

    # Error rate check
    - name: error-rate
      prometheus:
        query: |
          sum(rate(http_requests_total{
            service='{{args.service-name}}',
            status=~"5.."
          }[5m]))
          /
          sum(rate(http_requests_total{
            service='{{args.service-name}}'
          }[5m]))
      successCondition: result[0] <= 0.001    # ≤ 0.1% error
      failureCondition: result[0] > 0.005     # > 0.5% error

    # p99 latency
    - name: latency
      prometheus:
        query: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket{
              service='{{args.service-name}}'
            }[5m])) by (le)
          ) * 1000
      successCondition: result[0] < 500        # p99 < 500ms
      failureCondition: result[0] > 1000       # p99 > 1000ms
```

---

## Tổng kết cú pháp AnalysisTemplate

| Thành phần | Cú pháp |
|---|---|
| **CRD** | `apiVersion: argoproj.io/v1alpha1`, `kind: AnalysisTemplate` |
| **Args** | `args: [{name, value}]` — truyền vào Prometheus query bằng `{{args.name}}` |
| **Metric** | `metrics: [{name, interval, count, prometheus: {query}}]` |
| **Success** | `successCondition: result[0] >= 0.999` |
| **Failure** | `failureCondition: result[0] > 0.005` |
| **Inconclusive** | `inconclusiveCondition: result[0] == -1`, `inconclusiveBehavior: Continue` |
| **Builtin args** | `service-name`, `rollout-name`, `namespace`, `revision` |
| **Cluster scope** | `kind: ClusterAnalysisTemplate` — dùng chung mọi namespace |
