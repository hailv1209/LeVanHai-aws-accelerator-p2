# Progressive Delivery — Bài tập thực hành

---

## Lab 1: Full Canary Deployment với Auto-Abort

### Mục tiêu
Triển khai full progressive delivery pipeline: canary 10% → analysis → promote → full rollout, với auto-abort khi SLO metrics vi phạm.

### Các bước

**Bước 1: Chuẩn bị infrastructure**

```bash
# Đảm bảo các thành phần đã cài:
kubectl get namespaces | grep -E "argo-rollouts|monitoring"

# Argo Rollouts controller
kubectl get pods -n argo-rollouts

# Prometheus
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
```

**Bước 2: Tạo namespace**

```bash
kubectl create namespace progressive-demo
```

**Bước 3: Tạo Services**

```yaml
# services.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: progressive-demo

---
apiVersion: v1
kind: Service
metadata:
  name: app-stable
  namespace: progressive-demo
  labels:
    app: app
spec:
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: app
    track: stable

---
apiVersion: v1
kind: Service
metadata:
  name: app-canary
  namespace: progressive-demo
  labels:
    app: app
spec:
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: app
    track: canary
```

**Bước 4: Tạo AnalysisTemplate (Availability + Latency + Burn Rate)**

```yaml
# analysis-templates.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: availability-check
  namespace: progressive-demo
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 30s
      count: 5
      initialDelay: 15s
      successCondition: result[0] >= 0.999
      failureCondition: result[0] < 0.990
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

---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency-check
  namespace: progressive-demo
spec:
  args:
    - name: service-name
  metrics:
    - name: p99-latency
      interval: 30s
      count: 5
      successCondition: result[0] < 1000
      failureCondition: result[0] >= 1000
      prometheus:
        address: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket{
              service='{{args.service-name}}'
            }[{{metric.interval}}])) by (le)
          ) * 1000

---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: burn-rate-check
  namespace: progressive-demo
spec:
  args:
    - name: service-name
    - name: slo-target
      value: "0.999"
  metrics:
    - name: fast-burn
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
            ((1 - {{args.slo-target}}) / (24 * 60))
          )
```

```bash
kubectl apply -f services.yaml
kubectl apply -f analysis-templates.yaml
```

**Bước 5: Tạo Rollout với Analysis tích hợp**

```yaml
# rollout-full.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: app
  namespace: progressive-demo
spec:
  replicas: 10
  revisionHistoryLimit: 3

  selector:
    matchLabels:
      app: app

  template:
    metadata:
      labels:
        app: app
    spec:
      containers:
        - name: app
          image: paulbouwer/hello-kubernetes:1.10
          ports:
            - containerPort: 8080
          env:
            - name: MESSAGE
              value: "Version 1.0 — STABLE"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

  strategy:
    canary:
      stableService: app-stable
      canaryService: app-canary

      canaryMetadata:
        labels:
          track: canary
      stableMetadata:
        labels:
          track: stable

      steps:
        # Step 1: 10% canary
        - setWeight: 10

        # Step 2: Analysis — verify 10% canary
        - analysis:
            templates:
              - templateName: availability-check
              - templateName: latency-check
            args:
              - name: service-name
                value: app-canary
            startingStep: 2

        # Step 3: Tăng lên 30%
        - setWeight: 30

        # Step 4: Pause 5 phút (monitoring)
        - pause: {duration: 300}

        # Step 5: Analysis lần 2 — Burn rate check
        - analysis:
            templates:
              - templateName: burn-rate-check
              - templateName: availability-check
            args:
              - name: service-name
                value: app-canary
            startingStep: 5

        # Step 6: Tăng lên 60%
        - setWeight: 60

        # Step 7: Pause cho manual review
        - pause: {}

        # Step 8: Full rollout
        - setWeight: 100
```

```bash
kubectl apply -f rollout-full.yaml

# Quan sát
kubectl argo rollouts get rollout app -n progressive-demo --watch
```

**Kết quả mong đợi:**

```
Name: app
Strategy: Canary
Status: Healthy (Step 0/8)
```

**Bước 6: Upgrade lên v2**

```bash
# Upgrade image
kubectl argo rollouts set image app \
  app=paulbouwer/hello-kubernetes:1.11 \
  -n progressive-demo

# Quan sát canary bắt đầu
kubectl argo rollouts get rollout app -n progressive-demo --watch
```

**Kết quả mong đợi:**

```
Name: app
Strategy: Canary
Status: Paused (Step 1/8 — Analysis running)

STEP  SET WEIGHT  ANALYSIS
1/8   10%         ▶ (Running)
      └── availability: 99.97% (threshold: 99.9%) ✅
      └── p99-latency:  45ms (threshold: 1000ms) ✅
```

**Bước 7: Promote sau khi analysis pass**

```bash
# Argo Rollouts tự động promote nếu tất cả metrics pass
# Hoặc promote manual:
kubectl argo rollouts promote app -n progressive-demo

# Quan sát tiếp
kubectl argo rollouts get rollout app -n progressive-demo --watch
```

---

## Lab 2: Simulate Auto-Abort với Load Test

### Mục tiêu
Tạo tải gây lỗi để kích hoạt auto-abort từ AnalysisTemplate.

### Các bước

**Bước 1: Deploy v2 (bước đầu của rollout)**

```bash
# Deploy v2 với 10% canary
kubectl argo rollouts set image app \
  app=paulbouwer/hello-kubernetes:1.12 \
  -n progressive-demo
```

**Bước 2: Tạo load test script**

```bash
# create-load-generator.yaml
apiVersion: v1
kind: Pod
metadata:
  name: load-generator
  namespace: progressive-demo
spec:
  restartPolicy: Never
  containers:
    - name: siege
      image: yokogawa/siege:latest
      command: ["siege", "-t60S", "-c50", "-d5", "http://app-canary:80"]
```

```bash
kubectl apply -f create-load-generator.yaml
```

**Bước 3: Giả lập lỗi trên canary pods**

```bash
# Scale up canary replicas để tăng % canary
# (mô phỏng khi tất cả canary pods bị lỗi)

# Watch analysis fail
kubectl argo rollouts get rollout app -n progressive-demo --watch

# Hoặc xem AnalysisRun logs
kubectl argo rollouts get analysisrun -n progressive-demo

# Nếu metrics fail → Argo Rollouts tự abort
# Verify:
kubectl argo rollouts get rollout app -n progressive-demo
# Output: Aborted
```

**Bước 4: Verify rollback hoàn tất**

```bash
# Kiểm tra trạng thái
kubectl argo rollouts get rollout app -n progressive-demo

# Xem lịch sử
kubectl argo rollouts history app -n progressive-demo

# Xác nhận v1 vẫn healthy
kubectl get pods -n progressive-demo -l app=app
```

---

## Lab 3: Blue/Green với Smoke Test

### Mục tiêu
Triển khai blue/green với pre-promotion analysis (smoke test).

### Các bước

**Bước 1: Tạo Blue/Green Rollout**

```yaml
# bg-rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: app-bg
  namespace: progressive-demo
spec:
  replicas: 5
  selector:
    matchLabels:
      app: app-bg

  template:
    metadata:
      labels:
        app: app-bg
    spec:
      containers:
        - name: app
          image: paulbouwer/hello-kubernetes:1.10
          ports:
            - containerPort: 8080

  strategy:
    blueGreen:
      activeService: app-bg-active
      previewService: app-bg-preview

      previewReplicaCount: 2
      activeReplicaCount: 5

      autoPromotionEnabled: false   # Manual gate
      scaleDownDelaySeconds: 60

      # Pre-promotion smoke test
      prePromotionAnalysis:
        templates:
          - templateName: availability-check
        args:
          - name: service-name
            value: app-bg-preview
        startingStep: 1
```

```bash
kubectl apply -f bg-rollout.yaml
```

**Bước 2: Upgrade v2**

```bash
kubectl argo rollouts set image app-bg \
  app=paulbouwer/hello-kubernetes:1.11 \
  -n progressive-demo

# v2 được deploy với previewReplicaCount=2
# Traffic 100% vẫn ở v1 (active)
```

**Bước 3: Smoke test preview trước khi promote**

```bash
# Test preview service (v2)
kubectl exec -it load-generator -n progressive-demo -- \
  wget -q -O- http://app-bg-preview

# Verify message: "Version 1.11"

# Test active service (v1)
kubectl exec -it load-generator -n progressive-demo -- \
  wget -q -O- http://app-bg-active

# Verify message: "Version 1.10"
```

**Bước 4: Promote (switch traffic)**

```bash
# Sau khi smoke test pass (hoặc auto via prePromotionAnalysis)
kubectl argo rollouts promote app-bg -n progressive-demo

# Traffic switch: v1 → v2
# v1 scale down sau 60s
```

---

## Lab 4: Progressive Delivery với ArgoCD Integration

### Mục tiêu
Dùng ArgoCD để quản lý GitOps workflow cho progressive delivery.

### Các bước

**Bước 1: Tạo GitOps repository structure**

```bash
mkdir -p gitops-demo/apps/progressive-app/overlays/production
cd gitops-demo

# File structure:
# apps/progressive-app/
#   ├── base/
#   │   ├── kustomization.yaml
#   │   ├── rollout.yaml
#   │   └── services.yaml
#   └── overlays/
#       └── production/
#           ├── kustomization.yaml
#           └── analysis-templates.yaml
```

**Bước 2: Tạo base manifests**

```yaml
# apps/progressive-app/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - services.yaml
  - rollout.yaml
```

```yaml
# apps/progressive-app/base/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: app
spec:
  replicas: 10
  strategy:
    canary:
      canaryService: app-canary
      stableService: app-stable
      steps:
        - setWeight: 10
        - analysis:
            templates:
              - templateName: availability-check
            args:
              - name: service-name
                value: app-canary
        - setWeight: 30
        - pause: {duration: 300}
        - setWeight: 100
```

```bash
git init
git add .
git commit -m "Initial progressive delivery setup"
git remote add origin https://github.com/myorg/gitops-demo.git
git push -u origin main
```

**Bước 3: Tạo ArgoCD Application**

```yaml
# argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: progressive-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/gitops-demo.git
    targetRevision: HEAD
    path: apps/progressive-app/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: progressive-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
kubectl apply -f argocd-app.yaml
```

**Bước 4: GitOps workflow — Deploy v2**

```bash
# Cập nhật image trong Git
cd gitops-demo
git checkout -b release/v1.11
# Chỉnh sửa rollout.yaml hoặc kustomization.yaml để đổi image version
git add . && git commit -m "Release v1.11"
git push origin release/v1.11

# Tạo PR → Review → Merge vào main

# ArgoCD tự động sync manifest mới
# Argo Rollouts nhận manifest → bắt đầu canary
```

**Bước 5: GitOps Rollback**

```bash
# Khi cần rollback:
git revert HEAD
git push origin main

# ArgoCD sync → Argo Rollouts nhận manifest về version cũ
# → tự động rollback
```

---

## Lab 5: Dashboard theo dõi Progressive Delivery

### Mục tiêu
Tạo Grafana dashboard giám sát rollout progress + SLO metrics.

### Các bước

**Bước 1: Tạo Grafana dashboard JSON (panel definitions)**

```bash
# progressive-delivery-dashboard.json
# Panels:
# 1. Rollout Status (Stat: Healthy/Paused/Aborted)
# 2. Canary % (Gauge: 0-100)
# 3. Canary replicas vs Stable replicas (Time series)
# 4. Success Rate: Canary vs Stable (Time series)
# 5. Error Rate: Canary vs Stable (Time series)
# 6. p99 Latency: Canary vs Stable (Time series)
# 7. Rollout Events (log panel)
```

**Bước 2: Provision dashboard bằng ConfigMap**

```yaml
# grafana-progressive-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-progressive-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  progressive-delivery.json: |
    {
      "title": "Progressive Delivery Monitor",
      "tags": ["rollout", "canary", "argo-rollouts"],
      "panels": [
        {
          "title": "Rollout Status",
          "type": "stat",
          "targets": [
            {
              "expr": "argo_rollouts_info{namespace='progressive-demo', name='app'}",
              "legendFormat": "{{phase}}"
            }
          ]
        },
        {
          "title": "Canary Replicas",
          "type": "gauge",
          "targets": [
            {
              "expr": "kube_pod_owner{namespace='progressive-demo', owner_kind='Rollout', pod=~'.*canary.*'}",
              "legendFormat": "Canary Pods"
            }
          ]
        },
        {
          "title": "Availability: Stable vs Canary",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum(rate(http_server_requests_seconds_count{track='stable'}[5m])) by (track)",
              "legendFormat": "Stable"
            },
            {
              "expr": "sum(rate(http_server_requests_seconds_count{track='canary'}[5m])) by (track)",
              "legendFormat": "Canary"
            }
          ]
        },
        {
          "title": "Error Rate Comparison",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum(rate(http_server_requests_seconds_count{track='canary',status=~'5..'}[5m])) / sum(rate(http_server_requests_seconds_count{track='canary'}[5m])) * 100",
              "legendFormat": "Canary Error Rate %"
            },
            {
              "expr": "sum(rate(http_server_requests_seconds_count{track='stable',status=~'5..'}[5m])) / sum(rate(http_server_requests_seconds_count{track='stable'}[5m])) * 100",
              "legendFormat": "Stable Error Rate %"
            }
          ]
        }
      ]
    }
```

```bash
kubectl apply -f grafana-progressive-dashboard.yaml
```

**Bước 3: Truy cập dashboard**

```
Grafana → Dashboards → Browse → Progressive Delivery Monitor
→ Quan sát rollout progress theo thời gian thực
```

---

## Cleanup

```bash
# Xóa tất cả resources
kubectl delete -f services.yaml -f analysis-templates.yaml
kubectl delete -f rollout-full.yaml -f bg-rollout.yaml
kubectl delete rollout,svc,analysistemplate,analysisrun \
  --all -n progressive-demo
kubectl delete ns progressive-demo

# Xóa Grafana dashboard
kubectl delete -f grafana-progressive-dashboard.yaml
```
