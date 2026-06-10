# Argo Rollouts — Lý thuyết & Kiến trúc

---

## 1. Progressive Delivery là gì?

**Progressive Delivery** là chiến lược deploy nâng cao, thay vì switch hoàn toàn sang version mới ("big bang deploy"), ta đẩy traffic dần dần sang version mới, monitor metrics, và tự động rollback nếu có vấn đề.

```
┌──────────────────────────────────────────────────────────────────┐
│          PROGRESSIVE DELIVERY vs TRADITIONAL DEPLOY               │
├──────────────────────────────────────────────────────────────────┤
│  Traditional (Big Bang):                                          │
│    v1 (100%) ─────────────────────────────▶ v2 (100%)           │
│    → Risk: toàn bộ traffic chuyển cùng lúc                       │
│    → Rollback: khó khăn, phải chuyển ngược lại                  │
│                                                                  │
│  Progressive (Canary):                                            │
│    v1 (100%) ──▶ v1(90%) + v2(10%) ──▶ v1(50%) + v2(50%)       │
│                ──▶ v2(100%)                                       │
│    → Risk: chỉ 10% traffic dùng version mới ban đầu             │
│    → Rollback: giảm về 0% ngay lập tức                          │
│    → Decision: dựa trên metrics (latency, error rate...)          │
└──────────────────────────────────────────────────────────────────┘
```

**Các loại Progressive Delivery:**

| Chiến lược | Mô tả |
|---|---|
| **Canary** | % traffic chuyển dần sang version mới |
| **Blue/Green** | Tạo "green" environment song song, switch hoàn toàn |
| **Feature Flags** | Bật/tắt feature bằng config, không cần deploy |
| **A/B Testing** | Chia traffic theo rule (header, cookie, geography) |

---

## 2. Argo Rollouts là gì?

**Argo Rollouts** là Kubernetes Controller và kubectl plugin, cung cấp declarative rollout strategy cho Kubernetes, thay thế `kubectl rollout` cơ bản.

```
┌──────────────────────────────────────────────────────────────┐
│                  ARGO ROLLOUTS CORE CONCEPTS                  │
│                                                              │
│  Rollout CRD                                                │
│    ↳ Thay thế Deployment, khai báo strategy (canary/blue-green)│
│                                                              │
│  ReplicaSet  v1 ────────▶  ReplicaSet  v2                   │
│    (stable)                  (canary)                       │
│                                                              │
│  AnalysisTemplate CRD                                        │
│    ↳ Định nghĩa Prometheus query để verify canary           │
│                                                              │
│  ClusterAnalysisTemplate CRD                                 │
│    ↳ Shared templates across namespaces                       │
└──────────────────────────────────────────────────────────────┘
```

**Ưu điểm của Argo Rollouts:**

- ✅ **Automated verification**: Chạy Prometheus queries tự động trong quá trình rollout
- ✅ **Automated rollback**: Abort nếu metrics vi phạm threshold
- ✅ **Pause/Resume**: Dừng giữa chừng để manual review
- ✅ **Full Kubernetes integration**: Hỗ trợ HPA, Ingress, SMI, VirtualService
- ✅ **CLI + UI**: argo rollouts kubectl plugin + Argo CD dashboard

---

## 3. Rollout CRD — Cú pháp chi tiết

### 3.1 Cấu trúc tổng quan

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 10
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: my-app:v2
          ports:
            - containerPort: 8080
  strategy:
    canary:           # hoặc blueGreen, abTest
      canaryService: my-app-canary    # Service trỏ đến canary pod
      stableService: my-app-stable    # Service trỏ đến stable pod
      trafficRouting:    # Optional: advanced traffic management
        nginx:
          annotation:
            canary-weight: "10"
      steps:           # Các bước set % traffic
      analysis:        # Automated verification
```

### 3.2 Canary Strategy — Chi tiết

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: frontend
spec:
  replicas: 10
  revisionHistoryLimit: 3

  selector:
    matchLabels:
      app: frontend

  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: myorg/frontend:v2.0.0
          resources:
            requests:
              cpu: 100m
              memory: 128Mi

  strategy:
    canary:
      # ─── Services ───
      stableService: frontend-stable
      canaryService: frontend-canary

      # ─── Traffic Management ───
      trafficRouting:
        nginx:
          # Ingress annotation để control traffic
          stableIngress:
            name: frontend-ingress
          additionalIngressAnnotations:
            canary-weight: "10"

      # ─── Replicas cho canary vs stable ───
      canaryMetadata:
        labels:
          track: canary
      stableMetadata:
        labels:
          track: stable

      # ─── Steps (thứ tự thực hiện) ───
      steps:
        # Bước 1: Set 10% canary
        - setWeight: 10

        # Bước 2: Pause để manual review
        - pause: {}

        # Bước 3: Verify với AnalysisTemplate
        - analysis:
            templates:
              - templateName: frontend-success-rate
            args:
              - name: service-name
                value: frontend

        # Bước 4: Tăng lên 30%
        - setWeight: 30

        # Bước 5: Pause 10 phút (hoặc vĩnh viễn nếu không set duration)
        - pause: {duration: 10}

        # Bước 6: Tăng lên 50%
        - setWeight: 50

        # Bước 7: Pause để manual review lần cuối
        - pause: {}

        # Bước 8: Full traffic
        - setWeight: 100

      # ─── Auto-pilot: không cần manual steps ───
      # Nếu dùng analysis, có thể set auto:
      # maxSurge: "20%"
      # maxUnavailable: 0
```

### 3.3 Blue/Green Strategy

```yaml
strategy:
  blueGreen:
    # Service active (đang nhận traffic)
    activeService: frontend-active

    # Service preview (để test trước khi switch)
    previewService: frontend-preview

    # Số replicas cho active + preview
    previewReplicaCount: 5
    activeReplicaCount: 10

    # Auto promotion: tự động switch sau khi analysis pass
    autoPromotionEnabled: false
    autoPromotionSeconds: 300  # Tự promote sau 5 phút nếu không abort

    # Scale down old version sau bao lâu
    scaleDownDelaySeconds: 30
    scaleDownDelayRevisionLimit: 3  # Giữ 3 revisions trước khi scale down

    # Pre Promotion Analysis
    prePromotionAnalysis:
      templates:
        - templateName: smoke-test
      args:
        - name: service-name
          value: frontend

    # Post Promotion Analysis
    postPromotionAnalysis:
      templates:
        - templateName: success-rate-check
      args:
        - name: service-name
          value: frontend
```

### 3.4 A/B Testing Strategy

```yaml
strategy:
  canary:
    canaryService: frontend-canary
    stableService: frontend-stable

    trafficRouting:
      SMI:
        trafficSplit:
          # Chia traffic: 80% → v1, 20% → v2
          - weight: 80
            service: frontend-stable
          - weight: 20
            service: frontend-canary

    steps:
      # A/B test: giữ 20% canary vô thời hạn
      - setWeight: 20
      - pause: {}

    analysis:
      templates:
        - templateName: ab-test-metrics
      startingStep: 1
      when: "always"  # luôn chạy khi có canary
```

---

## 4. Các bước (Steps) trong Rollout

### 4.1 Loại Steps

```yaml
steps:
  # 1. Set weight (%)
  - setWeight: 10        # 10% traffic đến canary

  # 2. Pause vô thời hạn (chờ manual)
  - pause: {}

  # 3. Pause có thời hạn (đơn vị: giây)
  - pause: {duration: 300}  # 5 phút

  # 4. Experiment (chạy workload test song song)
  - experiment:
      templates:
        - name: load-test
          specRef: load-test-template

  # 5. Analysis (chạy verify)
  - analysis:
      templates:
        - templateName: success-rate
      args:
        - name: service-name
          value: my-app
      startingStep: 1
      when: "always"

  # 6. Set mirror (% traffic được mirror đến canary nhưng response bị bỏ qua)
  - setMirror: 25
    pause: {duration: 5}

  # 7. Inline analysis (định nghĩa query trực tiếp, không cần AnalysisTemplate)
  - analysis:
      templateName: inline-check
      args:
        - name: error-rate
          value: "0.01"
```

### 4.2 Step Flow Example

```
Rollout bắt đầu (v2 được deploy)

Step 1: setWeight 10
  → v1: 90% traffic
  → v2: 10% traffic (canary)

Step 2: pause {} (vô thời hạn)
  → Dừng tại đây, chờ manual approve
  → kubectl argo rollouts promote frontend

Step 3: analysis (chạy Prometheus query)
  → Query: success_rate > 99%
  → Nếu PASS → tiếp tục
  → Nếu FAIL → abort

Step 4: setWeight 30
  → v1: 70%
  → v2: 30%

Step 5: pause {duration: 600} (10 phút)
  → Tự động tiếp tục sau 10 phút

Step 6: setWeight 100
  → v1: 0%
  → v2: 100% (full rollout hoàn tất)
```

---

## 5. Pause Conditions

```yaml
strategy:
  canary:
    pauseConditions:
      # Pause nếu error rate > 5%
      - reason: CanaryCheck
        delay: 30s  # Chờ 30s trước khi check

    # Abort nếu metrics không đạt
    abortScaleDownDelaySeconds: 300  # Scale down sau 5 phút nếu abort
```

---

## 6. Argo Rollouts Commands

```bash
# ─── Cài đặt ───
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Cài kubectl plugin
brew install argocd-cli          # macOS
# hoặc
curl -sSL -o /usr/local/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.7.0/kubectl-argo-rollouts-linux-amd64
chmod +x /usr/local/bin/kubectl-argo-rollouts

# ─── Rollout Management ───
kubectl argo rollouts get rollout my-app -n default          # Xem trạng thái
kubectl argo rollouts list rollouts -n default               # Danh sách rollouts
kubectl argo rollouts status my-app -n default              # Trạng thái chi tiết
kubectl argo rollouts history my-app -n default             # Lịch sử revisions

# ─── Control Rollout ───
kubectl argo rollouts promote my-app -n default              # Tiếp tục (next step)
kubectl argo rollouts abort my-app -n default               # Hủy, quay về stable
kubectl argo rollouts pause my-app -n default               # Tạm dừng
kubectl argo rollouts resume my-app -n default              # Tiếp tục sau pause
kubectl argo rollouts undo my-app -n default               # Quay về revision trước
kubectl argo rollouts undo my-app --to-revision=3 -n default  # Quay về revision cụ thể

# ─── Watching ───
kubectl argo rollouts get rollout my-app -n default --watch  # Live watching

# ─── Tips ───
# Watch nhiều rollouts
kubectl argo rollouts list -n default | grep -v Healthy
```

---

## 7. Integration với ArgoCD

Argo Rollouts tích hợp hoàn hảo với ArgoCD — khi ArgoCD sync manifest chứa Rollout CRD, ArgoCD sẽ hiển thị rollout progress trên UI.

```yaml
# Trong ArgoCD Application manifest:
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/myorg/gitops.git
    path: apps/my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Trên ArgoCD UI, Rollout sẽ hiển thị:

```
[=====>            ] 40% — Step 3/8: Analysis running...
  ✅ Step 1: setWeight 10 (completed)
  ✅ Step 2: pause {} (approved)
  🔄 Step 3: analysis (running) → success_rate=99.95% (threshold: 99.9%)
  ⏳ Step 4: setWeight 30
  ⏳ Step 5: pause (10m)
```

---

## Tổng kết cú pháp Rollout

| Thành phần | Cú pháp |
|---|---|
| **Rollout CRD** | `apiVersion: argoproj.io/v1alpha1`, `kind: Rollout` |
| **Canary steps** | `setWeight: N`, `pause: {}`, `pause: {duration: N}` |
| **Analysis** | `analysis: {templates: [...], args: [...]}` |
| **Blue/Green** | `activeService`, `previewService`, `autoPromotionEnabled` |
| **Traffic routing** | `trafficRouting: {nginx/smi/virtualService}` |
| **Pause condition** | `pauseConditions: [{reason: ..., delay: ...}]` |
| **Abort** | `kubectl argo rollouts abort <name>` |
| **Promote** | `kubectl argo rollouts promote <name>` |
| **Undo** | `kubectl argo rollouts undo <name>` |
