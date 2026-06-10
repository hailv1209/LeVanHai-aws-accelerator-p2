# AnalysisTemplate — Bài tập thực hành

---

## Lab 1: Tạo AnalysisTemplate cho Availability Check

### Mục tiêu
Tạo AnalysisTemplate kiểm tra success rate > 99.9% trước khi promote.

### Các bước

**Bước 1: Tạo Prometheus deployment để sinh metrics (nếu chưa có)**

```bash
# Dùng lại Prometheus đã cài ở Day-2
# Verify Prometheus đang chạy
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus

# Lấy Prometheus URL
kubectl get svc -n monitoring -l app=prometheus
# Output: prometheus-operated.monitoring.svc.cluster.local:9090
```

**Bước 2: Tạo AnalysisTemplate**

```yaml
# analysis-template-availability.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-check
  namespace: canary-demo
spec:
  args:
    - name: service-name
      value: "hello-canary"

  metrics:
    # ─── Success Rate (Availability SLO 99.9%) ───
    - name: success-rate
      interval: 30s          # Chạy mỗi 30 giây
      count: 5               # Tối đa 5 lần
      initialDelay: 10s       # Đợi 10s trước khi bắt đầu
      successCondition: result[0] >= 0.999    # ≥ 99.9%
      failureCondition: result[0] < 0.990     # < 99.0% = fail

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}',
            status=~"2.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))

    # ─── Error Rate ───
    - name: error-rate
      interval: 30s
      count: 3
      successCondition: result[0] <= 0.001     # ≤ 0.1%
      failureCondition: result[0] > 0.005     # > 0.5%

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}',
            status=~"5.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))
```

```bash
kubectl apply -f analysis-template-availability.yaml
```

**Bước 3: Verify AnalysisTemplate đã tạo**

```bash
kubectl get analysistemplate -n canary-demo

kubectl describe analysistemplate success-rate-check -n canary-demo
```

---

## Lab 2: Tạo AnalysisTemplate cho Latency Check

### Mục tiêu
Tạo AnalysisTemplate kiểm tra p99 latency < 500ms.

### Các bước

**Bước 1: Tạo Latency AnalysisTemplate**

```yaml
# analysis-template-latency.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency-check
  namespace: canary-demo
spec:
  args:
    - name: service-name
      value: "hello-canary"
    - name: p99-threshold-ms
      value: "500"
    - name: p95-threshold-ms
      value: "200"

  metrics:
    # ─── p99 Latency ───
    - name: p99-latency
      interval: 30s
      count: 5
      successCondition: result[0] < {{args.p99-threshold-ms}}
      failureCondition: result[0] > 1000

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          histogram_quantile(0.99,
            sum(rate(http_server_requests_seconds_bucket{
              service='{{args.service-name}}'
            }[{{metric.interval}}])) by (le)
          ) * 1000

    # ─── p95 Latency ───
    - name: p95-latency
      interval: 30s
      count: 5
      successCondition: result[0] < {{args.p95-threshold-ms}}
      failureCondition: result[0] > 500

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          histogram_quantile(0.95,
            sum(rate(http_server_requests_seconds_bucket{
              service='{{args.service-name}}'
            }[{{metric.interval}}])) by (le)
          ) * 1000
```

```bash
kubectl apply -f analysis-template-latency.yaml
```

---

## Lab 3: Tạo AnalysisTemplate với Burn Rate

### Mục tiêu
Tạo AnalysisTemplate kiểm tra SLO burn rate — abort rollout khi burn rate vượt threshold.

### Các bước

**Bước 1: Tạo Burn Rate AnalysisTemplate**

```yaml
# analysis-template-burnrate.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: slo-burn-rate-check
  namespace: canary-demo
spec:
  args:
    - name: service-name
      value: "hello-canary"
    - name: slo-target
      value: "0.999"       # 99.9%

  metrics:
    # ─── Fast Burn Rate (5 phút) ───
    # Threshold: 14.4× → 1% error budget / giờ
    - name: fast-burn-rate
      interval: 1m
      count: 3
      initialDelay: 30s
      successCondition: result[0] < 14.4
      failureCondition: result[0] >= 14.4

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          (
            (
              sum(rate(http_server_requests_seconds_count{
                service='{{args.service-name}}',
                status=~"5.."
              }[5m]))
              /
              sum(rate(http_server_requests_seconds_count{
                service='{{args.service-name}}'
              }[5m]))
            )
            /
            (
              (1 - {{args.slo-target}})
              /
              (24 * 60)
            )
          )

    # ─── Error Rate (double check) ───
    - name: error-rate
      interval: 30s
      count: 5
      successCondition: result[0] <= 0.002    # ≤ 0.2%
      failureCondition: result[0] > 0.01      # > 1%

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}',
            status=~"5.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))

    # ─── Availability (complement check) ───
    - name: availability
      interval: 1m
      count: 3
      successCondition: result[0] >= {{args.slo-target}}
      failureCondition: result[0] < 0.995

      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}',
            status=~"2.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))
```

```bash
kubectl apply -f analysis-template-burnrate.yaml
```

**Bước 2: Tạo ClusterAnalysisTemplate (dùng chung mọi namespace)**

```yaml
# cluster-analysistemplate-slo.yaml
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: slo-metrics-check
spec:
  args:
    - name: service-name
    - name: slo-target
      value: "0.999"
    - name: max-p99-ms
      value: "500"

  metrics:
    - name: success-rate
      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}',
            status=~"2.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))
      successCondition: result[0] >= {{args.slo-target}}

    - name: p99-latency
      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          histogram_quantile(0.99,
            sum(rate(http_server_requests_seconds_bucket{
              service='{{args.service-name}}'
            }[{{metric.interval}}])) by (le)
          ) * 1000
      successCondition: result[0] < {{args.max-p99-ms}}

    - name: burn-rate
      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          (
            (
              sum(rate(http_server_requests_seconds_count{
                service='{{args.service-name}}',
                status=~"5.."
              }[5m]))
              /
              sum(rate(http_server_requests_seconds_count{
                service='{{args.service-name}}'
              }[5m]))
            )
            /
            ((1 - {{args.slo-target}}) / (24 * 60))
          )
      successCondition: result[0] < 14.4
      failureCondition: result[0] >= 14.4
```

```bash
kubectl apply -f cluster-analysistemplate-slo.yaml
```

---

## Lab 4: Rollout với Analysis — Canary tự động

### Mục tiêu
Deploy Rollout có integrated AnalysisTemplate để tự động verify canary.

### Các bước

**Bước 1: Tạo Rollout với Analysis trong mỗi step**

```yaml
# rollout-with-analysis.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: hello
  namespace: canary-demo
spec:
  replicas: 5
  revisionHistoryLimit: 3

  selector:
    matchLabels:
      app: hello

  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: paulbouwer/hello-kubernetes:1.10
          ports:
            - containerPort: 8080
          env:
            - name: MESSAGE
              value: "Hello from v1!"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

  strategy:
    canary:
      stableService: hello-stable
      canaryService: hello-canary

      # Metadata cho replicas
      canaryMetadata:
        labels:
          track: canary
      stableMetadata:
        labels:
          track: stable

      steps:
        # Step 1: 5% canary
        - setWeight: 5

        # Step 2: Analysis — kiểm tra 5%
        - analysis:
            templates:
              - templateName: success-rate-check
              - templateName: latency-check
            args:
              - name: service-name
                value: hello-canary
            startingStep: 2
            # when: "always"  # Luôn chạy ở step này

        # Step 3: Tăng lên 20%
        - setWeight: 20

        # Step 4: Pause 5 phút
        - pause: {duration: 300}

        # Step 5: Analysis lần 2
        - analysis:
            templates:
              - templateName: slo-burn-rate-check
              - templateName: latency-check
            args:
              - name: service-name
                value: hello-canary
            startingStep: 5

        # Step 6: Tăng lên 50%
        - setWeight: 50

        # Step 7: Pause để manual review
        - pause: {}

        # Step 8: Full rollout
        - setWeight: 100
```

```bash
kubectl apply -f rollout-with-analysis.yaml

# Theo dõi
kubectl argo rollouts get rollout hello -n canary-demo --watch
```

**Bước 2: Upgrade version và quan sát Analysis**

```bash
# Upgrade lên v2
kubectl argo rollouts set image hello \
  hello=paulbouwer/hello-kubernetes:1.11 \
  -n canary-demo

# Theo dõi trạng thái
kubectl argo rollouts get rollout hello -n canary-demo --watch
```

**Kết quả mong đợi:**

```
Name:    hello
Strategy: Canary
Status:  Paused (Step 2: Analysis)
Strategy: canary
  setWeight:    5
  selector:     app=hello
  replicas:
    desired:     5
    updated:     0
    current:     5
    available:   5
    unavailable: 0
 cana

STEP          SET WEIGHT  STRATEGY  STEP     SET WEIGHT  ANALYSIS
1/8           5%          ✓                            ✓ (Running)
2/8           Analysis ✓  ▶ Running
  └── success-rate     99.97% (threshold: 99.9%) ✅
  └── latency          120ms (threshold: 500ms)    ✅
```

**Bước 3: Xem AnalysisRun resource**

```bash
# Argo Rollouts tự tạo AnalysisRun cho mỗi analysis step
kubectl get analysisrun -n canary-demo

kubectl describe analysisrun -n canary-demo -l rollout-name=hello

# Xem chi tiết
kubectl get analysisrun -n canary-demo -o yaml
```

---

## Lab 5: Abort Criteria — Rollback tự động khi fail

### Mục tiêu
Kiểm tra rollback tự động khi AnalysisTemplate fail.

### Các bước

**Bước 1: Tạo AnalysisTemplate luôn fail (để test)**

```yaml
# analysis-template-always-fail.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: always-fail-test
  namespace: canary-demo
spec:
  args:
    - name: service-name
  metrics:
    - name: test-fail
      interval: 10s
      count: 1
      failureCondition: result[0] >= 0  # Luôn fail
      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}',
            status=~"5.."
          }[{{metric.interval}}]))
          /
          sum(rate(http_server_requests_seconds_count{
            service='{{args.service-name}}'
          }[{{metric.interval}}]))
```

```bash
kubectl apply -f analysis-template-always-fail.yaml
```

**Bước 2: Cập nhật Rollout để dùng AnalysisTemplate luôn fail**

```bash
# Patch rollout để test abort
kubectl argo rollouts set image hello \
  hello=paulbouwer/hello-kubernetes:1.12 \
  -n canary-demo

# Edit rollout để thay đổi analysis template
kubectl edit rollout hello -n canary-demo
# Đổi templateName từ success-rate-check → always-fail-test
```

**Bước 3: Quan sát Abort**

```bash
kubectl argo rollouts get rollout hello -n canary-demo --watch
```

**Kết quả mong đợi:**

```
Name:    hello
Strategy: Canary
Status:  Aborted
Message: Metric 'test-fail' assessed as Failed

# Rollout tự động:
# 1. Phát hiện metric fail
# 2. Abort rollout
# 3. Scale down canary về 0
# 4. Giữ nguyên stable version
```

**Bước 4: Verify rollback**

```bash
# Kiểm tra trạng thái
kubectl argo rollouts get rollout hello -n canary-demo

# Kiểm tra replicas
kubectl get pods -n canary-demo -l app=hello

# Vẫn còn v1 (stable), v2 (canary) đã bị abort
```

**Bước 5: Xem Rollout history để confirm**

```bash
kubectl argo rollouts history hello -n canary-demo

# Output:
# REVISION  STRATEGY  STEP  SET WEIGHT  CANARY WT  STATUS
# 3         Canary    -     -           0%          Aborted
# 2         Canary    -     -           0%          Aborted
# 1         Canary    -     -           0%          Healthy
```

---

## Lab 6: Verify Prometheus queries trước khi dùng trong AnalysisTemplate

### Mục tiêu
Chạy thử Prometheus queries trên Prometheus UI trước khi đưa vào AnalysisTemplate.

### Các bước

**Bước 1: Port-forward Prometheus**

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090
```

**Bước 2: Chạy các queries sau trên http://localhost:9090**

```
# 1. Tổng request rate
sum(rate(http_server_requests_seconds_count[5m]))

# 2. Success rate
sum(rate(http_server_requests_seconds_count{status=~"2.."}[5m]))
/
sum(rate(http_server_requests_seconds_count[5m]))

# 3. Error rate
sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
/
sum(rate(http_server_requests_seconds_count[5m]))

# 4. p99 latency (nếu có histogram)
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) * 1000

# 5. Burn rate (SLO 99.9%)
(
  sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
  /
  sum(rate(http_server_requests_seconds_count[5m]))
)
/
(
  (1 - 0.999)
  /
  (24 * 60)
)
```

**Bước 3: Test query với service label cụ thể**

```
# Thay thế {{args.service-name}} bằng giá trị thực
service='hello-canary'

# Verify query trả về giá trị hợp lệ (không phải NaN hoặc empty)
```

---

## Cleanup

```bash
kubectl delete -f analysis-template-availability.yaml
kubectl delete -f analysis-template-latency.yaml
kubectl delete -f analysis-template-burnrate.yaml
kubectl delete -f cluster-analysistemplate-slo.yaml
kubectl delete -f rollout-with-analysis.yaml
kubectl delete analysistemplate --all -n canary-demo
kubectl delete analysisrun --all -n canary-demo
```
